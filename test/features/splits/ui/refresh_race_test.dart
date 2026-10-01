// A guarded write whose refresh is overtaken by the bill poll's still reports
// what the fold made of it.
import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// Storage whose bill listing, the first thing a refresh reads, can be held.
/// Once armed, the n-th listing waits on gates[n].
class GatedStorage implements BillStorage {
  final InMemoryBillStorage inner = InMemoryBillStorage();
  bool armed = false;
  final List<Completer<void>> gates = [];
  int hits = 0;

  @override
  Future<String?> read(String key) => inner.read(key);
  @override
  Future<void> write(String key, String value) => inner.write(key, value);
  @override
  Future<void> delete(String key) => inner.delete(key);
  @override
  Future<int> sweepUnfinishedWrites() => inner.sweepUnfinishedWrites();
  @override
  Future<List<String>> keys(String prefix) async {
    if (armed && prefix == 'splitz_bill_' && hits < gates.length) {
      await gates[hits++].future;
    }
    return inner.keys(prefix);
  }
}

typedef Rig = (SplitsController, String, GatedStorage, BillStore);

Future<Rig> rig() async {
  final storage = GatedStorage();
  final store = BillStore(storage);
  final c = SplitsController(
    wallet: FakeWallet(),
    store: store,
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(1)),
    relay: InMemorySplitsRelay(),
  );
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
  await c.billKey(id); // so the poll's syncBill reaches _refresh
  await c.syncBill(id);
  return (c, id, storage, store);
}

List<String> setAside(SplitsController c) =>
    c.bills.single.setAside.map((a) => a.code).toList();

/// Runs [action], a guarded write, while the poll's sync starts a later
/// refresh; the write's own refresh is let go first. Returns what the caller
/// of [action] reads when it returns, and the bill's set-aside codes.
Future<(String?, List<String>)> race(
  Rig r,
  Future<void> Function() action,
) async {
  final (c, id, storage, store) = r;
  final ga = Completer<void>(), gb = Completer<void>();
  storage
    ..gates.addAll([ga, gb])
    ..armed = true;
  final before = (await store.read(id)).length;
  var aDone = false;
  String? seen;
  final a = action().then((_) {
    aDone = true;
    seen = c.lastError;
  });
  await pumpEventQueue();
  expect(storage.hits, 1);
  expect((await store.read(id)).length, before + 1);
  final b = c.syncBill(id);
  await pumpEventQueue();
  expect(storage.hits, 2);
  ga.complete();
  await pumpEventQueue();
  expect(aDone, isFalse, reason: 'its refresh waits for the later one');
  gb.complete();
  await a;
  await b;
  return (seen, setAside(c));
}

void main() {
  Future<void> ghostExpense(SplitsController c, String id) => c.addExpense(
    billId: id,
    paidBy: c.me,
    amountMinorUnits: 175000,
    among: [c.me, 'ghost'],
  );
  Future<void> ghostCash(SplitsController c, String id) =>
      c.recordCash(billId: id, to: 'ghost', amountMinorUnits: 175000);

  test('a refused expense is reported though the poll overtook it', () async {
    final r = await rig();
    final (seen, aside) = await race(r, () => ghostExpense(r.$1, r.$2));
    expect(seen, isNotNull);
    expect(aside, contains('unknown_participant'));
  });

  test(
    'a refused cash record is reported though the poll overtook it',
    () async {
      final r = await rig();
      final (seen, aside) = await race(r, () => ghostCash(r.$1, r.$2));
      expect(seen, isNotNull);
      expect(aside, contains('unknown_participant'));
    },
  );

  test('an expense the fold applies is no error in the same race', () async {
    final r = await rig();
    final (seen, aside) = await race(
      r,
      () => r.$1.addExpense(
        billId: r.$2,
        paidBy: r.$1.me,
        amountMinorUnits: 175000,
        among: [r.$1.me],
      ),
    );
    expect(seen, isNull);
    expect(aside, isEmpty);
    expect(r.$1.bills.single.bill.expenses, hasLength(1));
  });

  test('with nothing in between, a refusal is reported', () async {
    final (c, id, _, _) = await rig();
    await ghostExpense(c, id);
    expect(c.lastError, isNotNull);
  });
}
