/// Correcting and withdrawing an expense, through the screens.
///
/// §10.4 amends by entry id and replaces the target wholesale; §10.8 says an
/// expense is its author's. Both rules are the fold's, so what is asserted
/// here is that the screens reach them and never offer what they would refuse.
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

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

/// A bill carrying one expense this device wrote.
Future<String> billWithMyExpense(SplitsController c) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  await c.accept(id, [
    entries.joinBill(host: otherHost('ben'), name: 'ben', payTo: 'u1ben'),
  ]);
  await c.addExpense(
    billId: id,
    paidBy: c.me,
    amountMinorUnits: 9000,
    among: ['ben', c.me]..sort(),
    description: 'dinner',
  );
  return id;
}

void main() {
  group('correcting', () {
    testWidgets('the form opens on the whole expense, not part of it', (
      t,
    ) async {
      // An amendment replaces wholesale, so a form opened on half the entry
      // would submit a payload deleting the other half.
      final c = controllerFor(FakeWallet());
      final id = await billWithMyExpense(c);
      final view = c.bills.firstWhere((b) => b.id == id);
      final entryId = view.expenseEntries[view.bill.expenses.single.id]!;

      await t.pumpWidget(
        app(c, AddExpenseScreen(billId: id, editingEntryId: entryId)),
      );
      await t.pumpAndSettle();

      expect(find.text('Correct this expense'), findsOneWidget);
      expect(find.text('90.00'), findsOneWidget);
      expect(find.text('dinner'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('a correction replaces the expense and keeps its description', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithMyExpense(c);
      final view = c.bills.firstWhere((b) => b.id == id);
      final entryId = view.expenseEntries[view.bill.expenses.single.id]!;

      await t.pumpWidget(
        app(c, AddExpenseScreen(billId: id, editingEntryId: entryId)),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('splits_amount')), '60.00');
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('splits_expense_save')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_expense_save')));
      await t.pumpAndSettle();

      final after = c.bills.firstWhere((b) => b.id == id);
      // One expense, corrected — not a second one appended.
      expect(after.bill.expenses.length, 1);
      expect(after.bill.expenses.single.amount, 6000);
      expect(after.bill.expenses.single.description, 'dinner');
      expect(after.setAside, isEmpty);
    });

    testWidgets('correcting who paid reaches the bill', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithMyExpense(c);
      final view = c.bills.firstWhere((b) => b.id == id);
      final entryId = view.expenseEntries[view.bill.expenses.single.id]!;

      await t.pumpWidget(
        app(c, AddExpenseScreen(billId: id, editingEntryId: entryId)),
      );
      await t.pumpAndSettle();
      final ben = find.byKey(const Key('splits_paid_by_ben'));
      await t.ensureVisible(ben);
      await t.pumpAndSettle();
      await t.tap(ben);
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('splits_expense_save')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_expense_save')));
      await t.pumpAndSettle();

      final after = c.bills.firstWhere((b) => b.id == id);
      expect(after.bill.expenses.single.paidBy, 'ben');
      expect(after.bill.expenses.single.amount, 9000);
      expect(after.setAside, isEmpty);
    });

    testWidgets("somebody else's expense is shown and not offered", (t) async {
      // §10.4 would set aside the amendment; the screen does not invite it.
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      final ben = otherHost('ben');
      await c.accept(id, [
        entries.joinBill(host: ben, name: 'ben', payTo: 'u1ben'),
        entries.addExpense(
          host: ben,
          expenseId: 'x-ben',
          paidBy: 'ben',
          amount: 9000,
          split: <String, dynamic>{
            'type': 'equal',
            'among': ['ben', c.me]..sort(),
          },
          description: 'their dinner',
        ),
      ]);

      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.text('their dinner'), findsOneWidget);
      final tile = t.widget<InkWell>(
        find.byKey(const Key('splits_expense_x-ben')),
      );
      expect(tile.onTap, isNull);
      // Withdrawable, though: this device opened the bill, and §10.8 lets the
      // creator take any expense off it.
      expect(
        find.byKey(const Key('splits_expense_dismiss_x-ben')),
        findsOneWidget,
      );
    });

    testWidgets(
      'an expense entered for somebody else is still the enterer\'s',
      (t) async {
        // Ana enters what Ben paid. §10.4 gives the correction to Ana, who
        // wrote it; offering it to whoever paid would offer Ben an amendment
        // the fold refuses and leave Ana unable to fix her own typo.
        final c = controllerFor(FakeWallet());
        await c.load();
        final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
        await c.accept(id, [
          entries.joinBill(host: otherHost('ben'), name: 'ben', payTo: 'u1ben'),
        ]);
        await c.addExpense(
          billId: id,
          paidBy: 'ben',
          amountMinorUnits: 9000,
          among: ['ben', c.me]..sort(),
          description: 'taxi',
        );
        final expense = c.bills.single.bill.expenses.single;
        expect(c.bills.single.expenseAuthors[expense.id], c.me);

        await t.pumpWidget(app(c, BillScreen(billId: id)));
        await t.pumpAndSettle();

        final tile = t.widget<InkWell>(
          find.byKey(Key('splits_expense_${expense.id}')),
        );
        expect(tile.onTap, isNotNull);
      },
    );
  });

  group('withdrawing', () {
    testWidgets('a swipe asks first, and says the history keeps it', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithMyExpense(c);
      final expenseId = c.bills
          .firstWhere((b) => b.id == id)
          .bill
          .expenses
          .single
          .id;

      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();

      await t.drag(
        find.byKey(Key('splits_expense_dismiss_$expenseId')),
        const Offset(-500, 0),
      );
      await t.pumpAndSettle();

      expect(find.text('Take this off the bill?'), findsOneWidget);
      expect(find.textContaining('stays in the history'), findsOneWidget);

      // Backing out changes nothing.
      await t.tap(find.text('Keep it'));
      await t.pumpAndSettle();
      expect(c.bills.firstWhere((b) => b.id == id).bill.expenses, isNotEmpty);
    });

    testWidgets('confirming takes it off the bill and leaves it in the log', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithMyExpense(c);
      final expenseId = c.bills
          .firstWhere((b) => b.id == id)
          .bill
          .expenses
          .single
          .id;

      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      await t.drag(
        find.byKey(Key('splits_expense_dismiss_$expenseId')),
        const Offset(-500, 0),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_expense_withdraw_confirm')));
      await t.pumpAndSettle();

      final after = c.bills.firstWhere((b) => b.id == id);
      expect(after.bill.expenses, isEmpty);
      // Still written, and visible as withdrawn: removing it outright would
      // leave a reader unable to see it was ever there.
      expect(after.activity.any((e) => e.withdrawn), isTrue);
    });
  });
}
