// Taking somebody off a bill: out of the expenses this device wrote first,
// the others sharing their part; what it cannot change is said.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';
import 'package:zcash_wallet/src/features/splits/ui/view/removal_words.dart';

import 'support/fake_wallet.dart';

/// [who]'s removal as [me] would plan it, from what [store] holds.
Future<RemovalPlan> planAs(
  BillStore store,
  FakeWallet wallet,
  String id,
  String who,
  String me,
) async {
  final log = await store.read(id);
  final folded = foldUnverified(wallet, log, billId: id);
  return planRemoval(
    folded: folded,
    creatorId: log.firstWhere((e) => e['kind'] == 'createBill')['author'],
    log: log,
    id: who,
    me: me,
  );
}

/// [plan]'s blockers as the dialog words them, for [c]'s one bill.
List<String> _said(SplitsController c, RemovalPlan plan) => [
  for (final b in plan.blockers)
    removalBlockerSentence(
      b,
      bill: c.bills.single.bill,
      creatorId: c.bills.single.creatorId,
    ),
];

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
    final plan = (await t.runAsync(() => c.removalPlan(id, 'ben')))!;
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
    expect(find.text('Take them off'), findsOneWidget);
    // 30.00 among three is 10.00 each; without Ben, 15.00 for each of the
    // other two.
    expect(
      t.widget<Text>(find.byKey(const Key('splits_people_remove_moves'))).data,
      'Their 10.00 USD share of 1 expense moves to the others:',
    );
    expect(
      t
          .widget<Text>(find.byKey(const Key('splits_people_remove_moves_cai')))
          .data,
      '• Cai pays 5.00 USD more',
    );
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

  /// Ana's bill with Ben on it, where Ben paid for Hotel and shared a Taxi
  /// Ana wrote and paid. [anaWroteHotel] decides who entered the Hotel.
  Future<(SplitsController, String)> paidForHotel(
    WidgetTester t, {
    required bool anaWroteHotel,
  }) async {
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
      final ben = otherHost('ben');
      await c.accept(id, [
        entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
      ]);
      wallet.tick();
      if (anaWroteHotel) {
        await c.addExpense(
          billId: id,
          paidBy: 'ben',
          amountMinorUnits: 2000,
          among: [c.me, 'ben'],
          description: 'Hotel',
        );
      } else {
        await c.accept(id, [
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
      }
      wallet.tick();
      await c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 3000,
        among: [c.me, 'ben'],
        description: 'Taxi',
      );
    });
    expect(c.lastError, isNull);
    return (c, id);
  }

  Future<void> openRemoval(
    WidgetTester t,
    SplitsController c,
    String id,
  ) async {
    final ben = c.bills.single.bill.participant('ben')!;
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
  }

  testWidgets('somebody who paid for an expense stays on the bill: the reason '
      'is said and nothing is offered to write', (t) async {
    final (c, id) = await paidForHotel(t, anaWroteHotel: false);
    await openRemoval(t, c, id);

    expect(
      find.byKey(const Key('splits_people_remove_blocked')),
      findsOneWidget,
    );
    expect(find.text('Ben stays on the bill'), findsOneWidget);
    expect(find.text('• They paid for Hotel.'), findsOneWidget);
    // The taxi Ben shared is not offered on its own: written alone, it would
    // leave him on the bill sharing in nothing.
    expect(find.text('Take them off'), findsNothing);
    expect(find.byKey(const Key('splits_people_remove_all')), findsNothing);
    // Ben wrote the hotel, so this device cannot open it to change it.
    expect(find.textContaining('Edit'), findsNothing);
  });

  testWidgets('an expense this device wrote is offered to open and change', (
    t,
  ) async {
    final (c, id) = await paidForHotel(t, anaWroteHotel: true);
    await openRemoval(t, c, id);

    expect(find.text('• They paid for Hotel.'), findsOneWidget);
    final hotelEntry = c.bills.single.expenseEntries.entries
        .firstWhere(
          (e) =>
              c.bills.single.bill.expenses
                  .firstWhere((x) => x.id == e.key)
                  .description ==
              'Hotel',
        )
        .value;
    await t.tap(find.byKey(Key('splits_people_remove_open_$hotelEntry')));
    await t.pumpAndSettle();
    expect(find.byType(AddExpenseScreen), findsOneWidget);
  });

  testWidgets(
    'the controller writes no part of a removal that leaves them on',
    (t) async {
      final (c, id) = await paidForHotel(t, anaWroteHotel: false);
      final before = c.bills.single.bill.expenses.length;
      final plan = (await t.runAsync(() => c.removalPlan(id, 'ben')))!;
      expect(plan.edits, hasLength(1), reason: 'the taxi could be restated');
      expect(plan.complete, isFalse);

      await t.runAsync(
        () => c.restateExpenses(billId: id, without: 'ben', confirmed: plan),
      );
      expect(c.lastError, contains('still names them'));
      final bill = c.bills.single.bill;
      expect(bill.expenses, hasLength(before));
      final taxi = bill.expenses.firstWhere((e) => e.description == 'Taxi');
      expect(taxi.split['among'], contains('ben'));
    },
  );

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
    final plan = (await c.removalPlan(id, 'ben'))!;
    expect(plan.edits, isEmpty);
    expect(_said(c, plan), ['They paid for Hotel.']);
  });

  test('the creator restates an expense somebody else wrote', () async {
    final wallet = FakeWallet();
    final store = BillStore(InMemoryBillStorage());
    final c = SplitsController(
      wallet: wallet,
      store: store,
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
    expect((await planAs(store, wallet, id, 'ben', 'cai')).edits, isNotEmpty);
    expect(_said(c, await planAs(store, wallet, id, 'ben', 'dee')), [
      'Boat was added by Cai, who can take them out of it.',
    ]);

    final plan = (await c.removalPlan(id, 'ben'))!;
    expect(plan.blockers, isEmpty);
    wallet.tick();
    await c.restateExpenses(billId: id, without: 'ben', confirmed: plan);
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
