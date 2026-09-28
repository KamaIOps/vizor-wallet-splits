/// What the screens show and refuse for a name, a figure, a large text scale
/// and a long list.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

Widget app(SplitsController c, Widget home, {double textScale = 1}) =>
    SplitsScope(
      controller: c,
      child: MaterialApp(
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: home,
        ),
      ),
    );

void main() {
  testWidgets('joining asks for a name, and writes that name', (t) async {
    final ana = controllerFor(FakeWallet());
    await ana.load();
    final id = (await ana.createBill(
      name: 'Dinner',
      currency: 'USD',
      displayName: 'Ana',
    ))!;
    final scanned =
        entries.readScan((await ana.shareableBill(id))!) as entries.ScannedBill;

    final ben = controllerFor(FakeWallet(id: 'account-uuid-9', payTo: 'u1b'));
    await ben.load();
    await ben.acceptKey(id, scanned.invite!.key);
    await ben.accept(id, scanned.entries);

    await t.pumpWidget(app(ben, BillScreen(billId: id)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_bill_join')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('splits_bill_join_name')), 'Ben');
    await t.tap(find.byKey(const Key('splits_bill_join_ok')));
    await t.pumpAndSettle();

    final me = ben.bills.single.bill.participant(ben.me)!;
    expect(me.name, 'Ben');
    expect(me.name, isNot(contains('account-uuid-9')));
  });

  testWidgets('two people answering to one name are pointed out', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(
      name: 'Dinner',
      currency: 'USD',
      displayName: 'Ana',
    ))!;
    await c.accept(id, [
      entries.joinBill(host: otherHost('zzzzzzzz'), name: 'Ana', payTo: 'u1z'),
    ]);

    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(
      find.byKey(const Key('splits_bill_shared_name_Ana')),
      findsOneWidget,
    );
    // The other Ana is told apart by eight characters of their id, not four.
    expect(
      c.bills.single.bill.displayNameOf('zzzzzzzz', creatorId: c.me),
      'Ana (zzzzzzzz)',
    );
    expect(
      c.bills.single.bill.displayNameOf('xyzzzzzzzzz', creatorId: c.me),
      isNot('Ana (…zzzz)'),
    );
  });

  testWidgets('a share count that is not whole is refused, and the expense '
      'cannot be added', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    await c.accept(id, [
      entries.joinBill(host: otherHost('ben'), name: 'ben', payTo: 'u1ben'),
    ]);
    await t.pumpWidget(app(c, AddExpenseScreen(billId: id)));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('splits_amount')), '90.00');
    await t.tap(find.byKey(const Key('splits_split_shares')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(Key('splits_figure_${c.me}')), '1.5');
    await t.pumpAndSettle();
    expect(find.text('Whole shares only'), findsOneWidget);

    await t.ensureVisible(find.text('Add it'));
    await t.pumpAndSettle();
    await t.tap(find.text('Add it'));
    await t.pumpAndSettle();
    expect(c.bills.single.bill.expenses, isEmpty);
  });

  testWidgets('the split kinds are not clipped at twice the text size', (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    await t.pumpWidget(app(c, AddExpenseScreen(billId: id), textScale: 2));
    await t.pumpAndSettle();
    final chip = find.byKey(const Key('splits_split_equal'));
    final label = find.descendant(of: chip, matching: find.byType(Text));
    // The label sits wholly inside the chip, which is laid out at its own
    // height rather than at a row's.
    final chipBox = t.getRect(chip);
    final labelBox = t.getRect(label);
    expect(chipBox.top <= labelBox.top, isTrue);
    expect(chipBox.bottom >= labelBox.bottom, isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('the last person on a long list is not under the add button', (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    for (var i = 0; i < 20; i++) {
      await c.addPerson(billId: id, id: 'p$i', name: 'Person $i');
    }
    await t.pumpWidget(app(c, PeopleScreen(billId: id)));
    await t.pumpAndSettle();
    // Scrolled as far as it goes.
    await t.drag(find.byType(ListView), const Offset(0, -5000));
    await t.pumpAndSettle();
    // The list's own order, not the order they were added in.
    final lastId = c.bills.single.bill.participants
        .lastWhere((p) => p.id != c.me)
        .id;
    final last = find.byKey(Key('splits_person_remove_$lastId'));
    final button = t.getRect(find.byKey(const Key('splits_people_add')));
    expect(t.getRect(last).overlaps(button), isFalse);
  });
}
