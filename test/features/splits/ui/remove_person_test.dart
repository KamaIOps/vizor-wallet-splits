// Taking somebody off a bill: out of the expenses this device wrote first,
// the others sharing their part; what it cannot change is said.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';
import 'package:zcash_wallet/src/features/splits/ui/view/removal_plan.dart';

import 'support/fake_wallet.dart';

void main() {
  group('a split without somebody', () {
    test('equal and shares drop them; the rest share it', () {
      expect(
        splitWithout({
          'type': 'equal',
          'among': ['ana', 'ben', 'cai'],
        }, 'ben'),
        {
          'type': 'equal',
          'among': ['ana', 'cai'],
        },
      );
      expect(
        splitWithout({
          'type': 'shares',
          'shareCounts': {'ana': 1, 'ben': 2},
        }, 'ben'),
        {
          'type': 'shares',
          'shareCounts': {'ana': 1},
        },
      );
    });

    test('nobody left, or a figure that must still add up, is by hand', () {
      expect(
        splitWithout({
          'type': 'equal',
          'among': ['ben'],
        }, 'ben'),
        isNull,
      );
      expect(
        splitWithout({
          'type': 'exact',
          'amounts': {'ana': 500, 'ben': 500},
        }, 'ben'),
        isNull,
      );
      expect(
        splitWithout({
          'type': 'percentage',
          'basisPoints': {'ana': 5000, 'ben': 5000},
        }, 'ben'),
        isNull,
      );
    });

    test('itemized drops them per item; an item only they had is by hand', () {
      final shared = {
        'type': 'itemized',
        'extraMinorUnits': 0,
        'items': [
          {
            'description': 'pizza',
            'minorUnits': 1000,
            'sharedBy': ['ana', 'ben'],
          },
        ],
      };
      expect(
        (splitWithout(shared, 'ben')!['items'] as List).single['sharedBy'],
        ['ana'],
      );
      final theirs = {
        'type': 'itemized',
        'extraMinorUnits': 0,
        'items': [
          {
            'description': 'wine',
            'minorUnits': 1000,
            'sharedBy': ['ben'],
          },
        ],
      };
      expect(splitWithout(theirs, 'ben'), isNull);
    });
  });

  testWidgets('off every expense this device wrote, then off the bill', (
    t,
  ) async {
    final wallet = FakeWallet();
    final c = SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
    );
    late String id;
    await t.runAsync(() async {
      await c.load();
      id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
      await c.addPerson(billId: id, id: 'ben', name: 'Ben');
      await c.addPerson(billId: id, id: 'cai', name: 'Cai');
      wallet.tick();
      await c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 3000,
        among: [c.me, 'ben', 'cai'],
        description: 'Taxi',
      );
    });
    final ben = c.bills.single.bill.participant('ben')!;
    final plan = planRemoval(c.bills.single, 'ben', c.me);
    expect(plan.edits, hasLength(1));
    expect(plan.blockers, isEmpty);

    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  confirmAndRemovePerson(context, billId: id, participant: ben),
              child: const Text('remove'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('remove'));
    await t.pumpAndSettle();
    expect(find.text('Remove from all expenses'), findsOneWidget);
    wallet.tick();
    await t.runAsync(() async {
      await t.tap(find.byKey(const Key('splits_people_remove_all')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await t.pumpAndSettle();

    expect(c.lastError, isNull);
    final bill = c.bills.single.bill;
    expect(bill.participant('ben'), isNull);
    expect((bill.expenses.single.split['among'] as List).toSet(), {
      c.me,
      'cai',
    });
  });

  test('what this device cannot change is said, not done', () async {
    final wallet = FakeWallet();
    final c = SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
    );
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    final ben = otherHost('ben');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
      entries.addExpense(
        host: ben,
        expenseId: 'x1',
        paidBy: 'ben',
        amount: 2000,
        description: 'Hotel',
        split: <String, dynamic>{
          'type': 'equal',
          'among': ['ben', c.me]..sort(),
        },
      ),
    ]);
    final plan = planRemoval(c.bills.single, 'ben', c.me);
    expect(plan.edits, isEmpty);
    expect(plan.blockers, ['They paid for Hotel.']);
  });

  test('the creator restates an expense somebody else wrote', () async {
    final wallet = FakeWallet();
    final c = SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
    );
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    final ben = otherHost('ben');
    final cai = otherHost('cai');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
      entries.joinBill(host: cai, name: 'Cai', payTo: 'u1cai'),
      entries.addExpense(
        host: cai,
        expenseId: 'x1',
        paidBy: 'cai',
        amount: 3000,
        description: 'Boat',
        split: <String, dynamic>{
          'type': 'equal',
          'among': ['ben', 'cai', c.me]..sort(),
        },
      ),
    ]);

    // Anybody but the creator is told whose expense it is.
    expect(planRemoval(c.bills.single, 'ben', 'cai').edits, isNotEmpty);
    expect(planRemoval(c.bills.single, 'ben', 'dee').blockers, [
      'Boat was added by Cai, who can take them out of it.',
    ]);

    final plan = planRemoval(c.bills.single, 'ben', c.me);
    expect(plan.blockers, isEmpty);
    wallet.tick();
    await c.restateExpenses(
      billId: id,
      splits: {for (final e in plan.edits) e.entryId: e.split},
    );
    expect(c.lastError, isNull);
    wallet.tick();
    await c.removePerson(billId: id, id: 'ben');
    expect(c.lastError, isNull);

    final bill = c.bills.single.bill;
    expect(bill.participant('ben'), isNull);
    final boat = bill.expenses.single;
    expect((boat.paidBy, boat.amount, boat.description), ('cai', 3000, 'Boat'));
    expect((boat.split['among'] as List).toSet(), {'cai', c.me});
    expect(c.bills.single.setAside, isEmpty);
  });
}
