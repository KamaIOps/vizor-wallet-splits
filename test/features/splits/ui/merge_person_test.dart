// Somebody the creator added by hand, before the person joined from their own
// phone under another name: the creator says the two are one, and everything
// the hand-added name paid for or shared becomes theirs.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController _controller(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

/// This device opened the bill and added "Josh" by hand; Joshua joined from
/// his own phone after the expenses were written. Josh paid a 30.00 dinner
/// shared with this device, and shares a 20.00 taxi this device paid.
Future<String> _joshAndJoshua(SplitsController c, FakeWallet wallet) async {
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  await c.addPerson(billId: id, id: 'josh', name: 'Josh');
  await c.accept(id, [
    entries.joinBill(host: otherHost('joshua'), name: 'Joshua'),
  ]);
  wallet.tick();
  await c.addExpense(
    billId: id,
    paidBy: 'josh',
    amountMinorUnits: 3000,
    among: [c.me, 'josh'],
    description: 'Dinner',
  );
  wallet.tick();
  await c.addExpense(
    billId: id,
    paidBy: c.me,
    amountMinorUnits: 2000,
    among: [c.me, 'josh'],
    description: 'Taxi',
  );
  expect(c.lastError, isNull);
  return id;
}

Future<void> _openPeople(WidgetTester t, SplitsController c, String id) async {
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(home: PeopleScreen(billId: id)),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the creator says Josh is Joshua: one write, Josh comes off, '
      'Joshua holds what Josh held, and nobody else moves', (t) async {
    final wallet = FakeWallet();
    final c = _controller(wallet);
    late String id;
    late Map<String, int> before;
    await t.runAsync(() async {
      id = await _joshAndJoshua(c, wallet);
      before = protocol.netBalances(c.bills.single.bill);
    });
    await _openPeople(t, c, id);
    expect(find.byKey(Key('splits_person_merge_${c.me}')), findsNothing);

    await t.tap(find.byKey(const Key('splits_person_merge_josh')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_people_merge_into_joshua')));
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_people_merge_moves')), findsOneWidget);
    await t.tap(find.byKey(const Key('splits_people_merge_confirm')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pumpAndSettle();

    expect(c.lastError, isNull);
    final bill = c.bills.single.bill;
    expect(bill.participant('josh'), isNull);
    expect(
      bill.expenses.singleWhere((e) => e.description == 'Dinner').paidBy,
      'joshua',
    );
    final after = protocol.netBalances(bill);
    expect(after['joshua'], before['josh']! + before['joshua']!);
    expect(after[c.me], before[c.me]);
    expect(c.bills.single.folded!.setAside, isEmpty);
  });

  test(
    'a payment to Josh holds the merge back, and nothing is written',
    () async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      final id = await _joshAndJoshua(c, wallet);
      await c.accept(id, [
        entries.recordPayment(
          host: otherHost('joshua'),
          paymentId: 'p1',
          to: 'josh',
          amount: 500,
          method: 'cash',
        ),
      ]);
      final plan = (await c.removalPlan(id, 'josh', into: 'joshua'))!;
      expect(plan.complete, isFalse);
      final held = c.bills.single.bill.expenses.length;
      await c.removePerson(billId: id, id: 'josh', into: 'joshua');
      expect(c.lastError, isNotNull);
      expect(c.bills.single.bill.participant('josh'), isNotNull);
      expect(c.bills.single.bill.expenses, hasLength(held));
    },
  );

  test('closed for settling, nobody is merged until it is reopened', () async {
    final wallet = FakeWallet();
    final c = _controller(wallet);
    final id = await _joshAndJoshua(c, wallet);
    await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
    await c.closeForSettling(id);
    await c.removePerson(billId: id, id: 'josh', into: 'joshua');
    expect(c.lastError, contains('Reopen it to change expenses'));
    expect(c.bills.single.bill.participant('josh'), isNotNull);
    await c.reopen(id);
    await c.removePerson(billId: id, id: 'josh', into: 'joshua');
    expect(c.lastError, isNull);
    expect(c.bills.single.bill.participant('josh'), isNull);
  });

  testWidgets('a device that did not open the bill is not offered it', (
    t,
  ) async {
    late SplitsController ben;
    late String id;
    await t.runAsync(() async {
      final relay = InMemorySplitsRelay();
      final ana = SplitsController(
        wallet: FakeWallet(),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(1)),
        relay: relay,
      );
      ben = SplitsController(
        wallet: FakeWallet(id: 'ben', payTo: 'u1ben'),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(2)),
        relay: relay,
      );
      await ana.load();
      await ben.load();
      id = (await ana.createBill(name: 'Trip', currency: 'USD'))!;
      await ana.join(id, displayName: 'Ana');
      await ana.addPerson(billId: id, id: 'josh', name: 'Josh');
      await ben.acceptKey(id, await ana.billKey(id));
      await ana.syncBill(id);
      await ben.syncBill(id);
      await ben.join(id, displayName: 'Ben');
      await ben.syncBill(id);
    });
    await _openPeople(t, ben, id);
    expect(find.byKey(const Key('splits_person_josh')), findsOneWidget);
    expect(find.byKey(const Key('splits_person_merge_josh')), findsNothing);
    // And refused if asked anyway.
    await t.runAsync(
      () => ben.removePerson(billId: id, id: 'josh', into: ben.me),
    );
    expect(ben.lastError, isNotNull);
    expect(ben.bills.single.bill.participant('josh'), isNotNull);
  });
}
