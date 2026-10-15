// SPEC §15.5 and §11.3: every bill this device holds is synced together on one fixed
// tick, whatever is on screen; the bill a screen shows is not polled faster.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// [InMemorySplitsRelay], counting the fetches of each channel.
class _Counting implements SplitsRelay {
  final inner = InMemorySplitsRelay();
  final fetches = <String, int>{};

  @override
  Future<void> push(String channel, List<String> blobs) =>
      inner.push(channel, blobs);

  @override
  Future<List<String>> fetch(String channel) {
    fetches[channel] = (fetches[channel] ?? 0) + 1;
    return inner.fetch(channel);
  }
}

void main() {
  _tooLarge();

  testWidgets('one tick syncs every held bill, and nothing sooner', (t) async {
    final relay = _Counting();
    final c = SplitsController(
      wallet: FakeWallet(),
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(1)),
      relay: relay,
    );
    late String open, other;
    await t.runAsync(() async {
      await c.load();
      open = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
      other = (await c.createBill(name: 'Taxi', currency: 'EUR'))!;
    });
    final channels = {
      for (final id in [open, other]) id: SplitsChannel.forBill(id),
    };

    c.pollBill(open);
    await t.pump(const Duration(seconds: relaySyncSeconds - 1));
    expect(relay.fetches, isEmpty, reason: 'the open bill is not synced first');

    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(relay.fetches, {channels[open]: 1, channels[other]: 1});

    await t.pump(const Duration(seconds: relaySyncSeconds));
    await t.pump();
    expect(relay.fetches, {channels[open]: 2, channels[other]: 2});

    c.stopPolling(open);
    await t.pump(const Duration(seconds: relaySyncSeconds * 2));
    expect(relay.fetches, {channels[open]: 2, channels[other]: 2});
  });
}

void _tooLarge() {
  test('an entry no sealed update carries is refused in words, and not '
      'written (§11.3)', () async {
    final c = SplitsController(
      wallet: FakeWallet(),
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(2)),
      relay: const UnconfiguredSplitsRelay(),
    );
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    final before = c.bills.single.entryCount;
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 1000,
      among: [c.me],
      description: 'x' * 33000,
    );
    expect(c.lastError, 'This is too long to send. Shorten it.');
    expect(c.bills.single.entryCount, before);
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 1000,
      among: [c.me],
      description: 'Wine',
    );
    expect(c.lastError, isNull);
    expect(c.bills.single.entryCount, before + 1);
  });
}
