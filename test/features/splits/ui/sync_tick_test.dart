// SPEC §15.5: every held bill syncs on one tick for as long as the splits
// screens are up, whatever is on screen; a write that moves money pulls first;
// leaving pushes what was written; a slow push never holds back a pull.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'settle_send_test.dart' show owingBen;
import 'support/fake_wallet.dart';

/// [InMemorySplitsRelay], counting requests, with a fetch that can be made
/// to fail and a push on one channel that can be held.
class _Relay implements SplitsRelay {
  _Relay([InMemorySplitsRelay? inner]) : inner = inner ?? InMemorySplitsRelay();
  final InMemorySplitsRelay inner;
  final fetches = <String, int>{};
  final pushes = <String, int>{};
  bool down = false;
  String? held;
  final release = Completer<void>();

  @override
  Future<void> push(String channel, List<String> blobs) async {
    if (down) throw const SplitsRelayException('unreachable');
    if (channel == held) await release.future;
    pushes[channel] = (pushes[channel] ?? 0) + 1;
    return inner.push(channel, blobs);
  }

  @override
  Future<List<String>> fetch(String channel) async {
    if (down) throw const SplitsRelayException('unreachable');
    fetches[channel] = (fetches[channel] ?? 0) + 1;
    return inner.fetch(channel);
  }
}

SplitsController _controller(SplitsRelay relay, SplitsKeys keys) =>
    SplitsController(
      wallet: FakeWallet(),
      store: BillStore(InMemoryBillStorage()),
      keys: keys,
      relay: relay,
    );

Future<void> _settle(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
  await t.pump();
}

void main() {
  group('a withdrawal pulls the bill first', () {
    // [ben] decides what is on the relay before the payer taps Withdraw:
    // Ben's confirmation, nothing, or a relay that cannot be reached.
    Future<(SplitsController, String)> withdrawSoonAfterOpening(
      WidgetTester t, {
      required bool benConfirmed,
      bool relayDown = false,
    }) async {
      final relay = _Relay();
      final wallet = FakeWallet();
      final keys = SplitsKeys(store: InMemorySecretStore(), random: Random(3));
      final c = SplitsController(
        wallet: wallet,
        store: BillStore(InMemoryBillStorage()),
        keys: keys,
        relay: relay,
      );
      late String id, payment;
      await t.runAsync(() async {
        id = await owingBen(c);
        await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
        payment = c.bills.single.bill.payments.single.id;
        await c.syncBill(id);
        if (benConfirmed) {
          wallet.tick();
          final confirm = entries.confirmPayment(
            host: otherHost('ben'),
            paymentId: payment,
            method: 'recipientConfirmed',
            record: c.bills.single.paymentDigests[payment]!,
          );
          await relay.push(SplitsChannel.forBill(id), [
            await SplitsSealing().seal(confirm, (await keys.readBillKey(id))!),
          ]);
        }
      });
      c.startSyncing();
      relay.down = relayDown;
      await t.pumpWidget(
        SplitsScope(
          controller: c,
          child: MaterialApp(home: SettleScreen(billId: id)),
        ),
      );
      await t.pump(const Duration(seconds: 3));
      await t.tap(find.byKey(const Key('splits_settle_withdraw_ben')));
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const Key('splits_settle_withdraw_confirm')));
      await _settle(t);
      await t.pump(const Duration(seconds: 1));
      return (c, payment);
    }

    testWidgets('a confirmation on the relay keeps the payment', (t) async {
      final (c, payment) = await withdrawSoonAfterOpening(
        t,
        benConfirmed: true,
      );
      final bill = c.bills.single.bill;
      expect(bill.payments.map((p) => p.id), contains(payment));
      expect(bill.confirmedPayments, contains(payment));
      expect(
        c.lastError,
        'This payment was confirmed as arrived, so it stays on the bill.',
      );
      c.dispose();
    });

    testWidgets('a relay that cannot be read refuses the withdrawal', (
      t,
    ) async {
      final (c, payment) = await withdrawSoonAfterOpening(
        t,
        benConfirmed: true,
        relayDown: true,
      );
      expect(c.bills.single.bill.payments.map((p) => p.id), contains(payment));
      expect(c.lastError, contains('Could not check the bill'));
      c.dispose();
    });

    testWidgets('with nothing new on the relay, the payment is withdrawn', (
      t,
    ) async {
      final (c, payment) = await withdrawSoonAfterOpening(
        t,
        benConfirmed: false,
      );
      expect(c.lastError, isNull);
      expect(
        c.bills.single.bill.payments.map((p) => p.id),
        isNot(contains(payment)),
      );
      c.dispose();
    });
  });

  group('the tick runs whatever is on screen', () {
    /// One account on two devices, the bill on both.
    Future<(SplitsController, SplitsController, _Relay, String)> twoDevices(
      WidgetTester t,
    ) async {
      final shared = InMemorySplitsRelay();
      final relayA = _Relay(shared);
      final keysA = SplitsKeys(store: InMemorySecretStore(), random: Random(5));
      final keysB = SplitsKeys(store: InMemorySecretStore(), random: Random(6));
      final a = _controller(relayA, keysA);
      final b = _controller(_Relay(shared), keysB);
      late String id;
      await t.runAsync(() async {
        id = await owingBen(a);
        await a.syncBill(id);
        await b.load();
        await keysB.storeBillKey(id, (await keysA.readBillKey(id))!);
        await b.syncBill(id);
      });
      return (a, b, relayA, id);
    }

    int paid(SplitsController c) =>
        c.bills.single.bill.payments.fold<int>(0, (n, p) => n + p.amount);

    testWidgets('a write with no bill on screen is pushed at the next tick', (
      t,
    ) async {
      final (a, b, relayA, id) = await twoDevices(t);
      a.startSyncing();
      await t.runAsync(
        () => a.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000),
      );
      await t.pump(const Duration(seconds: relaySyncSeconds));
      await _settle(t);
      await t.runAsync(() => b.syncBill(id));
      expect(paid(b), 1000);
      a.dispose();
    });

    testWidgets('leaving before the tick pushes what was written', (t) async {
      final (a, b, relayA, id) = await twoDevices(t);
      a.startSyncing();
      await t.runAsync(
        () => a.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000),
      );
      final before = relayA.pushes[SplitsChannel.forBill(id)] ?? 0;
      a.dispose();
      await _settle(t);
      expect(relayA.pushes[SplitsChannel.forBill(id)], before + 1);
      await t.runAsync(() => b.syncBill(id));
      expect(paid(b), 1000);
    });

    testWidgets('a write the app was killed before pushing is pushed by the '
        'next launch', (t) async {
      final shared = InMemorySplitsRelay();
      final storage = InMemoryBillStorage();
      final keysA = SplitsKeys(store: InMemorySecretStore(), random: Random(5));
      final keysB = SplitsKeys(store: InMemorySecretStore(), random: Random(6));
      SplitsController device(SplitsKeys keys, BillStorage storage) =>
          SplitsController(
            wallet: FakeWallet(),
            store: BillStore(storage),
            keys: keys,
            relay: _Relay(shared),
          );
      final a = device(keysA, storage);
      final b = device(keysB, InMemoryBillStorage());
      late String id;
      await t.runAsync(() async {
        id = await owingBen(a);
        await a.syncBill(id);
        await b.load();
        await keysB.storeBillKey(id, (await keysA.readBillKey(id))!);
        await b.syncBill(id);
        // Written, and the process ends here: no tick, no dispose, no push.
        await a.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
        await b.syncBill(id);
      });
      expect(paid(b), 0);

      // The next launch: the same storage and keychain, a new controller.
      final again = device(keysA, storage);
      await t.runAsync(again.load);
      again.startSyncing();
      await t.pump(const Duration(seconds: relaySyncSeconds));
      await _settle(t);
      await t.runAsync(() => b.syncBill(id));
      expect(paid(b), 1000);
      again.dispose();
    });

    testWidgets('without startSyncing, nothing runs on a timer', (t) async {
      final (a, _, relayA, id) = await twoDevices(t);
      final before = relayA.fetches[SplitsChannel.forBill(id)];
      await t.pump(const Duration(seconds: relaySyncSeconds * 3));
      expect(relayA.fetches[SplitsChannel.forBill(id)], before);
      a.dispose();
    });

    testWidgets('a held push on one bill does not hold back another\'s pull', (
      t,
    ) async {
      final relay = _Relay();
      final c = _controller(
        relay,
        SplitsKeys(store: InMemorySecretStore(), random: Random(1)),
      );
      late String x, y;
      await t.runAsync(() async {
        await c.load();
        x = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
        y = (await c.createBill(name: 'Taxi', currency: 'EUR'))!;
      });
      final ids = [x, y]..sort();
      final slow = ids.first, other = ids.last;
      relay.held = SplitsChannel.forBill(slow);
      c.startSyncing();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(seconds: relaySyncSeconds));
        await _settle(t);
      }
      expect(relay.fetches[SplitsChannel.forBill(other)], 4);
      expect(relay.fetches[SplitsChannel.forBill(slow)], 4);
      expect(relay.pushes[SplitsChannel.forBill(slow)], isNull);
      relay.release.complete();
      await _settle(t);
      expect(relay.pushes[SplitsChannel.forBill(slow)], 1);
      c.dispose();
    });

    testWidgets('Sync now pulls every held bill, not the one on screen', (
      t,
    ) async {
      final relay = _Relay();
      final c = _controller(
        relay,
        SplitsKeys(store: InMemorySecretStore(), random: Random(2)),
      );
      late String x, y;
      await t.runAsync(() async {
        await c.load();
        x = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
        y = (await c.createBill(name: 'Taxi', currency: 'EUR'))!;
        await c.syncNow();
      });
      expect(relay.fetches, {
        SplitsChannel.forBill(x): 1,
        SplitsChannel.forBill(y): 1,
      });
      c.dispose();
    });
  });
}
