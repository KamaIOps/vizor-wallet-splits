// Taking somebody off is one write (§10.8): a sync cannot land between the
// expenses moving and the person coming off, and two at once write one.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

Future<(SplitsController, String, entries.BillHost)> setup() async {
  final wallet = FakeWallet();
  final c = SplitsController(
    wallet: wallet,
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  );
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
  ]);
  await c.addPerson(billId: id, id: 'cai', name: 'Cai');
  wallet.tick();
  await c.addExpense(
    billId: id,
    paidBy: c.me,
    amountMinorUnits: 3000,
    among: [c.me, 'ben', 'cai'],
    description: 'Taxi',
  );
  return (c, id, ben);
}

void main() {
  test(
    'taking somebody off writes the restated expense and the join at once',
    () async {
      final (c, id, _) = await setup();
      final plan = (await c.removalPlan(id, 'cai'))!;
      expect(plan.complete, isTrue);
      await c.removePerson(billId: id, id: 'cai', confirmed: plan);
      expect(c.lastError, isNull);
      final bill = c.bills.single.bill;
      expect(bill.participant('cai'), isNull);
      expect(bill.expenses.single.split['among'], isNot(contains('cai')));
    },
  );

  test('a peer expense naming them that lands after keeps them on, and a '
      'fresh plan takes them off', () async {
    final (c, id, ben) = await setup();
    final plan = (await c.removalPlan(id, 'cai'))!;
    await c.removePerson(billId: id, id: 'cai', confirmed: plan);
    await c.accept(id, [
      entries.addExpense(
        host: ben,
        expenseId: 'x2',
        paidBy: 'ben',
        amount: 900,
        description: 'Coffee',
        split: <String, dynamic>{
          'type': 'equal',
          'among': ['ben', 'cai'],
        },
      ),
    ]);
    // §10.8: the withdrawal of their join is refused while the Coffee names
    // them, and the Taxi stays restated: nothing is lost, and nothing counts
    // twice.
    expect(c.bills.single.bill.participant('cai'), isNotNull);
    expect(
      c.bills.single.bill.expenses.where((e) => e.description == 'Taxi').length,
      1,
    );
    final again = (await c.removalPlan(id, 'cai'))!;
    expect(again.complete, isTrue);
    await c.removePerson(billId: id, id: 'cai', confirmed: again);
    expect(c.lastError, isNull);
    expect(c.bills.single.bill.participant('cai'), isNull);
  });

  test(
    'V01 re-check: two restates of one plan at once on one device',
    () async {
      final (c, id, _) = await setup();
      final plan = (await c.removalPlan(id, 'cai'))!;
      final errs = <String?>[];
      await Future.wait([
        c
            .removePerson(billId: id, id: 'cai', confirmed: plan)
            .then((_) => errs.add(c.lastError)),
        c
            .removePerson(billId: id, id: 'cai', confirmed: plan)
            .then((_) => errs.add(c.lastError)),
      ]);
      final taxis = c.bills.single.bill.expenses
          .where((e) => e.description == 'Taxi')
          .length;
      expect(taxis, 1);
    },
  );
}
