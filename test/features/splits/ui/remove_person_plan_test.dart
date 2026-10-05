// Taking somebody off a bill when the bill moves under the dialog: a second
// removal in flight, a correction synced in, somebody named only by the entry
// an amendment corrects, and a split the fold would refuse.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';
import 'package:zcash_wallet/src/features/splits/ui/view/removal_words.dart';

import 'support/fake_wallet.dart';

const _changed =
    'The bill changed since you looked. Check who is on what, then try again.';

/// Storage whose bill writes wait while [hold] is set.
class _Held extends InMemoryBillStorage {
  bool hold = false;
  final List<Completer<void>> waiting = [];

  @override
  Future<void> write(String key, String value) async {
    if (hold && key.startsWith('splitz_bill_')) {
      final gate = Completer<void>();
      waiting.add(gate);
      await gate.future;
    }
    return super.write(key, value);
  }
}

SplitsController _controller(FakeWallet wallet, [BillStorage? storage]) =>
    SplitsController(
      wallet: wallet,
      store: BillStore(storage ?? InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
    );

Widget _host(SplitsController c, String id, protocol.Participant who) =>
    SplitsScope(
      controller: c,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                confirmAndRemovePerson(context, billId: id, participant: who),
            child: const Text('remove'),
          ),
        ),
      ),
    );

int _total(SplitsController c) =>
    c.bills.single.bill.expenses.fold<int>(0, (s, e) => s + e.amount);

/// A taxi of 30.00 this device paid, split by it, Ben and Cai.
Future<String> _taxi(SplitsController c, FakeWallet wallet) async {
  await c.load();
  final id = (await c.createBill(
    name: 'Trip',
    currency: 'USD',
    displayName: 'Ana',
  ))!;
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
  return id;
}

Future<void> _release(WidgetTester t, _Held storage) async {
  await t.runAsync(() async {
    storage.hold = false;
    for (var i = 0; i < 20; i++) {
      for (final g in [...storage.waiting]) {
        if (!g.isCompleted) g.complete();
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await t.pumpAndSettle();
}

/// A boat Cai wrote and paid, shared by Ben, Cai and this device, on a bill
/// this device opened.
Future<(String, Map<String, dynamic>, entries.BillHost)> _boat(
  SplitsController c,
) async {
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final cai = otherHost('cai');
  final boat = entries.addExpense(
    host: cai,
    expenseId: 'x1',
    paidBy: 'cai',
    amount: 4000,
    description: 'Boat',
    split: <String, dynamic>{
      'type': 'equal',
      'among': ['ben', 'cai', c.me]..sort(),
    },
  );
  await c.accept(id, [
    entries.joinBill(host: otherHost('ben'), name: 'Ben', payTo: 'u1ben'),
    entries.joinBill(host: cai, name: 'Cai', payTo: 'u1cai'),
    boat,
  ]);
  return (id, boat, cai);
}

/// Cai's correction of [boat] to include Dee, who joins with it.
List<Map<String, dynamic>> _deeOnBoat(
  SplitsController c,
  Map<String, dynamic> boat,
  entries.BillHost cai,
) => [
  entries.joinBill(host: otherHost('dee'), name: 'Dee', payTo: 'u1dee'),
  entries.amendEntry(
    host: cai,
    targetId: boat['id'] as String,
    member: protocol.payloadForKind['addExpense']!,
    payload: {
      ...(boat['expense'] as Map<String, dynamic>),
      'split': <String, dynamic>{
        'type': 'equal',
        'among': ['ben', 'cai', 'dee', c.me]..sort(),
      },
    },
  ),
];

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
  group('a second removal while the first is writing', () {
    testWidgets('the remove control does not fire while a write is held', (
      t,
    ) async {
      final storage = _Held();
      final wallet = FakeWallet();
      final c = _controller(wallet, storage);
      late String id;
      await t.runAsync(() async => id = await _taxi(c, wallet));
      await t.pumpWidget(
        SplitsScope(
          controller: c,
          child: MaterialApp(home: PeopleScreen(billId: id)),
        ),
      );
      await t.pumpAndSettle();
      wallet.tick();
      storage.hold = true;
      for (var round = 0; round < 2; round++) {
        await t.tap(find.byKey(const Key('splits_person_remove_ben')));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pumpAndSettle();
        final all = find.byKey(const Key('splits_people_remove_all'));
        if (round == 1) {
          // Held: no dialog opens, so nothing is planned against a bill
          // about to change.
          expect(all, findsNothing);
          expect(
            t
                .widget<IconButton>(
                  find.byKey(const Key('splits_person_remove_ben')),
                )
                .onPressed,
            isNull,
          );
          break;
        }
        await t.tap(all);
        await t.pumpAndSettle();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await t.pump();
      }
      await _release(t, storage);
      expect(_total(c), 3000);
      expect(c.bills.single.bill.expenses, hasLength(1));
    });

    test(
      'two restatements of one plan: one is written, one is refused',
      () async {
        final wallet = FakeWallet();
        final c = _controller(wallet);
        final id = await _taxi(c, wallet);
        final plan = (await c.removalPlan(id, 'ben'))!;
        wallet.tick();
        final errors = <String?>[];
        await Future.wait([
          c
              .restateExpenses(billId: id, without: 'ben', confirmed: plan)
              .then((_) => errors.add(c.lastError)),
          c
              .restateExpenses(billId: id, without: 'ben', confirmed: plan)
              .then((_) => errors.add(c.lastError)),
        ]);
        expect(_total(c), 3000);
        expect(c.bills.single.bill.expenses, hasLength(1));
        expect(
          (c.bills.single.bill.expenses.single.split['among'] as List).toSet(),
          {c.me, 'cai'},
        );
        expect(errors, contains(_changed));
      },
    );

    test(
      'the same plan confirmed again after it was written is refused',
      () async {
        final wallet = FakeWallet();
        final c = _controller(wallet);
        final id = await _taxi(c, wallet);
        final plan = (await c.removalPlan(id, 'ben'))!;
        wallet.tick();
        await c.restateExpenses(billId: id, without: 'ben', confirmed: plan);
        expect(c.lastError, isNull);
        wallet.tick();
        await c.restateExpenses(billId: id, without: 'ben', confirmed: plan);
        expect(c.lastError, _changed);
        expect(_total(c), 3000);
      },
    );
  });

  group('a correction synced in while the dialog is open', () {
    testWidgets('is not undone: nothing is written and the person is told', (
      t,
    ) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      late Map<String, dynamic> boat;
      late entries.BillHost cai;
      await t.runAsync(() async => (id, boat, cai) = await _boat(c));
      final ben = c.bills.single.bill.participant('ben')!;
      await t.pumpWidget(_host(c, id, ben));
      await t.tap(find.text('remove'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      expect(find.text('Take them off'), findsOneWidget);

      await t.runAsync(() => c.accept(id, _deeOnBoat(c, boat, cai)));
      final entriesBefore = c.bills.single.entryCount;

      wallet.tick();
      await t.runAsync(() async {
        await t.tap(find.byKey(const Key('splits_people_remove_all')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await t.pumpAndSettle();
      expect(c.lastError, _changed);
      final view = c.bills.single;
      expect(view.entryCount, entriesBefore);
      expect(view.bill.participant('ben'), isNotNull);
      expect((view.bill.expenses.single.split['among'] as List).toSet(), {
        'ben',
        'cai',
        'dee',
        c.me,
      });
    });

    test('planned after it landed, the correction is kept', () async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      final (id, boat, cai) = await _boat(c);
      await c.accept(id, _deeOnBoat(c, boat, cai));
      final plan = (await c.removalPlan(id, 'ben'))!;
      wallet.tick();
      await c.restateExpenses(billId: id, without: 'ben', confirmed: plan);
      expect(c.lastError, isNull);
      final boatNow = c.bills.single.bill.expenses.single;
      expect((boatNow.split['among'] as List).toSet(), {'cai', 'dee', c.me});
      expect((boatNow.paidBy, boatNow.amount), ('cai', 4000));
    });
  });

  group('somebody named only by the entry an amendment corrects', () {
    testWidgets('is offered, and comes off the bill', (t) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      await t.runAsync(() async {
        id = await _taxi(c, wallet);
        wallet.tick();
        await c.editExpense(
          billId: id,
          entryId: c.bills.single.expenseEntries.values.single,
          split: {
            'type': 'equal',
            'among': [c.me, 'cai'],
          },
        );
      });
      expect(c.lastError, isNull);
      final ben = c.bills.single.bill.participant('ben')!;
      await t.pumpWidget(_host(c, id, ben));
      await t.tap(find.text('remove'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      expect(find.text('They’re on no expense or payment.'), findsNothing);
      expect(find.text('Take them off'), findsOneWidget);
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
      expect(_total(c), 3000);
    });

    test('an amendment adding them names them too', () async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      final (id, boat, cai) = await _boat(c);
      await c.accept(id, _deeOnBoat(c, boat, cai));
      final plan = (await c.removalPlan(id, 'dee'))!;
      expect(plan.namesThem, isTrue);
      expect(removalEditName(plan.edits.single), 'Boat');
    });

    testWidgets('somebody on nothing is still told so, and comes off', (
      t,
    ) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      await t.runAsync(() async {
        id = await _taxi(c, wallet);
        await c.addPerson(billId: id, id: 'dee', name: 'Dee');
      });
      final dee = c.bills.single.bill.participant('dee')!;
      await t.pumpWidget(_host(c, id, dee));
      await t.tap(find.text('remove'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      expect(find.text('They’re on no expense or payment.'), findsOneWidget);
      wallet.tick();
      await t.runAsync(() async {
        await t.tap(find.byKey(const Key('splits_people_remove_confirm')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await t.pumpAndSettle();
      expect(c.lastError, isNull);
      expect(c.bills.single.bill.participant('dee'), isNull);
    });
  });

  group('read as the fold reads it', () {
    test('two copies of one expense are one restatement', () async {
      final wallet = FakeWallet();
      final store = BillStore(InMemoryBillStorage());
      final c = SplitsController(
        wallet: wallet,
        store: store,
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        relay: const UnconfiguredSplitsRelay(),
      );
      final id = await _taxi(c, wallet);
      final taxi = (await store.read(
        id,
      )).firstWhere((e) => e['kind'] == 'addExpense');
      await store.merge(id, [
        {...taxi, 'sig': 'BBBB'},
      ]);
      final copies = (await store.read(
        id,
      )).where((e) => e['id'] == taxi['id']).length;
      expect(copies, 2);
      final plan = (await c.removalPlan(id, 'ben'))!;
      expect(plan.edits, hasLength(1));
      wallet.tick();
      await c.restateExpenses(billId: id, without: 'ben', confirmed: plan);
      expect(c.lastError, isNull);
      expect(_total(c), 3000);
      expect(c.bills.single.bill.expenses, hasLength(1));
    });

    for (final (name, onlyNaming) in [
      ('an earlier amendment does not stand in for a withdrawn one', false),
      ('a withdrawn amendment naming them does not count', true),
    ]) {
      test(name, () async {
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
        await c.addPerson(billId: id, id: 'cai', name: 'Cai');
        await c.addPerson(billId: id, id: 'dee', name: 'Dee');
        wallet.tick();
        await c.addExpense(
          billId: id,
          paidBy: c.me,
          amountMinorUnits: 3000,
          among: [c.me, 'cai'],
          description: 'Taxi',
        );
        final entryId = c.bills.single.expenseEntries.values.single;
        for (final among in [
          [c.me, 'cai', 'dee'],
          if (!onlyNaming) [c.me, 'cai'],
        ]) {
          wallet.tick();
          await c.editExpense(
            billId: id,
            entryId: entryId,
            split: {'type': 'equal', 'among': among},
          );
        }
        final last = (await store.read(
          id,
        )).lastWhere((e) => e['kind'] == 'amendEntry');
        wallet.tick();
        await c.withdraw(billId: id, entryId: last['id'] as String);
        expect(c.lastError, isNull);
        // The fold reads the expense as written, which never named Dee.
        expect((await c.removalPlan(id, 'dee'))!.namesThem, isFalse);
        wallet.tick();
        await c.removePerson(billId: id, id: 'dee');
        expect(c.lastError, isNull);
        expect(c.bills.single.bill.participant('dee'), isNull);
      });
    }
  });

  group('a split the fold would refuse is not offered', () {
    test('shares where only they held one', () async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      await c.load();
      final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
      await c.addPerson(billId: id, id: 'ben', name: 'Ben');
      wallet.tick();
      await c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 3000,
        split: {
          'type': 'shares',
          'shareCounts': {'ben': 1, c.me: 0},
        },
        description: 'Ben’s ticket',
      );
      expect(c.lastError, isNull);
      final plan = (await c.removalPlan(id, 'ben'))!;
      expect(plan.edits, isEmpty);
      expect(_said(c, plan), ['Ben’s ticket needs its split changed by hand.']);
    });

    test('splitWithout: zero shares left is by hand, some left is not', () {
      expect(
        splitWithout({
          'type': 'shares',
          'shareCounts': {'ana': 0, 'ben': 2, 'cai': 0},
        }, 'ben'),
        isNull,
      );
      expect(
        splitWithout({
          'type': 'shares',
          'shareCounts': {'ana': 0, 'ben': 2, 'cai': 1},
        }, 'ben'),
        {
          'type': 'shares',
          'shareCounts': {'ana': 0, 'cai': 1},
        },
      );
    });
  });

  group('whose an expense is once it is written again', () {
    testWidgets('the dialog says the creator takes it over', (t) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      await t.runAsync(() async => (id, _, _) = await _boat(c));
      final ben = c.bills.single.bill.participant('ben')!;
      await t.pumpWidget(_host(c, id, ben));
      await t.tap(find.text('remove'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      expect(
        find.text('• Boat becomes yours to correct, not Cai’s.'),
        findsOneWidget,
      );
    });

    testWidgets('and says nothing of it for an expense already its own', (
      t,
    ) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      await t.runAsync(() async => id = await _taxi(c, wallet));
      final ben = c.bills.single.bill.participant('ben')!;
      await t.pumpWidget(_host(c, id, ben));
      await t.tap(find.text('remove'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('becomes yours'), findsNothing);
    });
  });
}
