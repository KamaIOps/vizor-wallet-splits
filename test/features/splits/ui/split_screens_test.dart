/// Dividing an expense five ways, through the screen.
///
/// The protocol defines five methods and refuses a sixth. What these assert is
/// that each one is reachable, that what it writes is §4's own shape, and that
/// a split the protocol would refuse cannot be submitted.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' show Expense;
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

/// A bill with two people on it, ready for an expense.
Future<String> billWithTwo(SplitsController c) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  await c.accept(id, [
    entries.joinBill(host: otherHost('ben'), name: 'ben', payTo: 'u1ben'),
  ]);
  return id;
}

/// Opens the add-expense screen with an amount already typed.
Future<void> openWith(
  WidgetTester t,
  SplitsController c,
  String id,
  String amount,
) async {
  await t.pumpWidget(app(c, AddExpenseScreen(billId: id)));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('splits_amount')), amount);
  await t.pumpAndSettle();
}

void main() {
  group('all five are reachable', () {
    testWidgets('every method has a chip, and no sixth does', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await t.pumpWidget(app(c, AddExpenseScreen(billId: id)));
      await t.pumpAndSettle();

      for (final kind in SplitKind.values) {
        expect(
          find.byKey(Key('splits_split_${kind.name}')),
          findsOneWidget,
          reason: '${splitKindLabel(kind)} is not reachable',
        );
      }
      expect(find.byType(ChoiceChip), findsNWidgets(SplitKind.values.length));
    });
  });

  group('what each one writes', () {
    testWidgets('exact amounts reach the bill as exact amounts', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await openWith(t, c, id, '90.00');

      await t.tap(find.byKey(const Key('splits_split_exact')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(Key('splits_figure_${c.me}')), '60.00');
      await t.enterText(find.byKey(const Key('splits_figure_ben')), '30.00');
      await t.pumpAndSettle();

      await t.ensureVisible(find.text('Add it'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add it'));
      await t.pumpAndSettle();

      final expense = c.bills
          .firstWhere((b) => b.id == id)
          .bill
          .expenses
          .single;
      expect(expense.split['type'], 'exact');
      expect((expense.split['amounts'] as Map)[c.me], 6000);
      expect((expense.split['amounts'] as Map)['ben'], 3000);
    });

    testWidgets('shares reach the bill as weights', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await openWith(t, c, id, '90.00');

      await t.tap(find.byKey(const Key('splits_split_shares')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(Key('splits_figure_${c.me}')), '2');
      await t.pumpAndSettle();

      await t.ensureVisible(find.text('Add it'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add it'));
      await t.pumpAndSettle();

      final expense = c.bills
          .firstWhere((b) => b.id == id)
          .bill
          .expenses
          .single;
      expect(expense.split['type'], 'shares');
      expect((expense.split['shareCounts'] as Map)[c.me], 2);
      expect((expense.split['shareCounts'] as Map)['ben'], 1);
    });

    testWidgets('switching the kind clears the figures the last one showed', (
      t,
    ) async {
      // A figure typed as a share count means nothing as a percentage. A
      // field that kept showing it while the draft held nothing for it would
      // store a split other than the one on screen.
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await openWith(t, c, id, '90.00');

      await t.tap(find.byKey(const Key('splits_split_shares')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(Key('splits_figure_${c.me}')), '2');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_split_percentage')));
      await t.pumpAndSettle();

      final field = t.widget<EditableText>(
        find.descendant(
          of: find.byKey(Key('splits_figure_${c.me}')),
          matching: find.byType(EditableText),
        ),
      );
      // What the draft holds for a percentage now, not the share count.
      expect(field.controller.text, '0.00');
    });

    testWidgets('percentages are stored in basis points', (t) async {
      // 33.33% is 3333. No double ever touches an amount.
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await openWith(t, c, id, '90.00');

      await t.tap(find.byKey(const Key('splits_split_percentage')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(Key('splits_figure_${c.me}')), '33.33');
      await t.enterText(find.byKey(const Key('splits_figure_ben')), '66.67');
      await t.pumpAndSettle();

      await t.ensureVisible(find.text('Add it'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add it'));
      await t.pumpAndSettle();

      final expense = c.bills
          .firstWhere((b) => b.id == id)
          .bill
          .expenses
          .single;
      expect(expense.split['type'], 'percentage');
      expect((expense.split['basisPoints'] as Map)[c.me], 3333);
    });

    testWidgets('an itemized split carries its lines and its extra', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await openWith(t, c, id, '90.00');

      // The chip row scrolls; `itemized` is the fifth and sits off an 800px
      // surface.
      await t.ensureVisible(find.byKey(const Key('splits_split_itemized')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_split_itemized')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('splits_item_add')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_item_add')));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('splits_item_name_0')), 'tacos');
      await t.enterText(find.byKey(const Key('splits_item_cost_0')), '80.00');
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('splits_item_0_${c.me}')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('splits_item_extra')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('splits_item_extra')), '10.00');
      await t.pumpAndSettle();

      await t.ensureVisible(find.text('Add it'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add it'));
      await t.pumpAndSettle();

      final expense = c.bills
          .firstWhere((b) => b.id == id)
          .bill
          .expenses
          .single;
      expect(expense.split['type'], 'itemized');
      expect(expense.split['extraMinorUnits'], 1000);
      final items = expense.split['items'] as List;
      expect(items.single['description'], 'tacos');
      expect(items.single['minorUnits'], 8000);
    });
  });

  group('a split the protocol refuses cannot be submitted', () {
    testWidgets('exact amounts that miss the total say so, and block the add', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await openWith(t, c, id, '90.00');

      await t.tap(find.byKey(const Key('splits_split_exact')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(Key('splits_figure_${c.me}')), '60.00');
      await t.enterText(find.byKey(const Key('splits_figure_ben')), '20.00');
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_split_refusal')), findsOneWidget);
      // The button is disabled rather than the add being refused later: the
      // protocol's answer is shown before anything is written.
      await t.ensureVisible(find.text('Add it'));
      await t.pumpAndSettle();
      final button = t.widget<FilledButton>(
        find.ancestor(
          of: find.text('Add it'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('percentages short of 100 say what they come to', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await openWith(t, c, id, '90.00');

      await t.tap(find.byKey(const Key('splits_split_percentage')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(Key('splits_figure_${c.me}')), '30.00');
      await t.enterText(find.byKey(const Key('splits_figure_ben')), '60.00');
      await t.pumpAndSettle();

      expect(find.textContaining('90.00%'), findsOneWidget);
    });

    testWidgets('an itemized split with nothing in it says to add one', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await openWith(t, c, id, '90.00');

      // The chip row scrolls; `itemized` is the fifth and sits off an 800px
      // surface.
      await t.ensureVisible(find.byKey(const Key('splits_split_itemized')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_split_itemized')));
      await t.pumpAndSettle();

      expect(find.text('Add at least one item'), findsOneWidget);
    });
  });

  group('the entry cap (§2.2)', () {
    Future<List<Expense>> add(WidgetTester t, String amount) async {
      final c = controllerFor(FakeWallet());
      final id = await billWithTwo(c);
      await openWith(t, c, id, amount);
      await t.ensureVisible(find.text('Add it'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add it'));
      await t.pumpAndSettle();
      return c.bills.firstWhere((b) => b.id == id).bill.expenses;
    }

    testWidgets('an expense at the cap is added', (t) async {
      final expenses = await add(t, '922337203.68');
      expect(expenses.single.amount, 92233720368);
    });

    testWidgets('one unit over it is refused on the screen', (t) async {
      final expenses = await add(t, '922337203.69');
      expect(expenses, isEmpty);
      expect(find.textContaining('At most'), findsOneWidget);
    });
  });
}
