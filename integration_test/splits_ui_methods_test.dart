/// §4's five ways of dividing a cost, through the form a person types into.
///
/// The protocol's corpus pins what each split means. This pins that the screen
/// can reach all five, that a draft with no figures is refused in the draft's
/// own words rather than accepted and folded into nonsense, and that the
/// figures a person typed come back when the expense is reopened.
///
///     flutter test integration_test/splits_ui_methods_test.dart -d <device> \
///       --dart-define=VIZOR_FORM_FACTOR=mobile \
///       --dart-define=ZCASH_DEFAULT_NETWORK=regtest
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zcash_wallet/app.dart';

import 'support/mobile_regtest_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets(
    'every split §4 defines is reachable from the form',
    (tester) async {
      tolerateRenderOverflows();
      final defaultHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception is SocketException) return;
        defaultHandler?.call(details);
      };

      await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
      await createWalletWithPasscode(tester);

      GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/splits');
      await tester.pumpAndSettle(const Duration(seconds: 10));

      await _tapText(tester, 'Start a bill');
      await _typeInto(tester, 'What is it for', 'Methods');
      await _tapText(tester, 'Open the bill');
      await _settle(tester);

      // A second person, so there is something to divide between.
      await _tapKey(tester, 'splits_bill_people');
      await _tapKey(tester, 'splits_people_add');
      await tester.enterText(
        find.byKey(const Key('splits_people_name')),
        'Bob',
      );
      await tester.pump();
      await _tapKey(tester, 'splits_people_name_ok');
      await _settle(tester);
      expect(find.text('Bob'), findsWidgets);
      await _back(tester);
      logE2e('two people on the bill');

      // ── Equally, which needs no figures ──────────────────────────────
      await _tapText(tester, 'Add expense');
      await _typeInto(tester, 'What was it for?', 'Dinner');
      await tester.enterText(find.byKey(const Key('splits_amount')), '30');
      await tester.pump();
      expect(find.byKey(const Key('splits_split_equal')), findsOneWidget);
      expect(
        _figureKeys(tester),
        isEmpty,
        reason: 'an equal split asks for no figures',
      );
      await _tapText(tester, 'Add');
      await _settle(tester);
      await _expenseWritten(tester);
      await _reveal(tester, find.text('Dinner'), 'the equal-split expense');
      expect(find.text('Dinner'), findsWidgets);
      logE2e('equal: 30.00 added');

      // ── Exact, which is refused until the figures add up ─────────────
      await _tapText(tester, 'Add expense');
      await _typeInto(tester, 'What was it for?', 'Exactly');
      await tester.enterText(find.byKey(const Key('splits_amount')), '30');
      await tester.pump();
      await _revealChip(tester, 'splits_split_exact');
      await _tapKey(tester, 'splits_split_exact');
      expect(
        find.byKey(const Key('splits_split_refusal')),
        findsOneWidget,
        reason: 'a draft with no figures says why, in §4\'s own terms',
      );
      final figures = _figureKeys(tester);
      expect(figures.length, 2, reason: 'one field per person sharing it');
      await tester.enterText(find.byKey(figures[0]), '12');
      await tester.enterText(find.byKey(figures[1]), '18');
      await tester.pump();
      await _settle(tester);
      expect(
        find.byKey(const Key('splits_split_refusal')),
        findsNothing,
        reason: '12.00 and 18.00 come to the 30.00 the form was given',
      );
      await _tapText(tester, 'Add');
      await _settle(tester);
      await _expenseWritten(tester);
      await _reveal(tester, find.text('Exactly'), 'the exact-split expense');
      expect(find.text('Exactly'), findsWidgets);
      logE2e('exact: 12.00 and 18.00');

      // ── Reopening it brings the method and the figures back ──────────
      await _tapText(tester, 'Exactly');
      await _settle(tester);
      expect(find.text('Correct this expense'), findsOneWidget);
      final reopened = _figureKeys(tester);
      expect(
        reopened.length,
        2,
        reason: 'the exact split it was saved with, not the default',
      );
      await _back(tester);
      logE2e('exact reopened with its figures');

      // ── Percentages ──────────────────────────────────────────────────
      await _addWithFigures(
        tester,
        'Percent',
        '50',
        'splits_split_percentage',
        ['40', '60'],
      );
      logE2e('percentage: 40 and 60');

      // ── Shares ───────────────────────────────────────────────────────
      await _addWithFigures(tester, 'Shares', '30', 'splits_split_shares', [
        '2',
        '1',
      ]);
      logE2e('shares: two to one');

      // ── By item, with a cost apportioned across the items ────────────
      await _tapText(tester, 'Add expense');
      await _typeInto(tester, 'What was it for?', 'Itemised');
      // The total is still typed. `_splitRefusal` is computed against it, and an
      // empty Amount makes it null — which enables the submit button and makes
      // every refusal check on this form vacuous, whatever the items say.
      // 20.00 of tacos, 10.00 of beer and 3.00 of service is 33.00.
      await tester.enterText(find.byKey(const Key('splits_amount')), '33');
      await tester.pump();
      await _revealChip(tester, 'splits_split_itemized');
      await _tapKey(tester, 'splits_split_itemized');
      await _tapKey(tester, 'splits_item_add');
      await tester.enterText(
        find.byKey(const Key('splits_item_name_0')),
        'Tacos',
      );
      await tester.enterText(find.byKey(const Key('splits_item_cost_0')), '20');
      await tester.pump();
      await _tapKey(tester, 'splits_item_add');
      await tester.enterText(
        find.byKey(const Key('splits_item_name_1')),
        'Beer',
      );
      await tester.enterText(find.byKey(const Key('splits_item_cost_1')), '10');
      await tester.pump();
      // Tax, tip or service is apportioned by what each person's items came to,
      // never split evenly.
      await tester.enterText(find.byKey(const Key('splits_item_extra')), '3');
      await tester.pump();
      await _settle(tester);

      // §4's itemised split names whoever shares an item, and nobody else. Two
      // items with costs and nothing assigned is a draft that divides a cost
      // between no one, and the form refuses it in the draft's own words — the
      // refusal has to be seen before it can mean anything when it goes away.
      await _reveal(
        tester,
        find.byKey(const Key('splits_split_refusal')),
        'the refusal for an itemised draft nobody shares',
      );
      expect(
        find.byKey(const Key('splits_split_refusal')),
        findsOneWidget,
        reason: 'no item is shared by anyone yet',
      );
      logE2e('itemised with nothing assigned is refused');

      // Tacos to one person, beer to the other.
      for (var item = 0; item < 2; item++) {
        final chips = _keysWithPrefix(tester, 'splits_item_${item}_');
        expect(chips.length, 2, reason: 'one chip per person, on item $item');
        await tester.tap(find.byKey(chips[item]));
        await _settle(tester);
      }
      expect(
        find.byKey(const Key('splits_split_refusal')),
        findsNothing,
        reason: 'every item is shared by somebody, so the draft divides',
      );

      await _tapText(tester, 'Add');
      await _settle(tester);
      await _expenseWritten(tester);
      await _reveal(tester, find.text('Itemised'), 'the itemised expense');
      expect(find.text('Itemised'), findsWidgets);
      logE2e('itemised: two items, one each, and an apportioned extra');

      logE2e('split methods walkthrough complete');
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

/// Adds an expense under [chip], typing one figure per person sharing it.
/// Waits for the add-expense screen to close, which is what says the expense
/// was written.
///
/// Tapping a button that is disabled, or one whose form refuses what is in it,
/// throws nothing and leaves the screen where it was. Searching for the
/// expense's own name afterwards does not settle it: that name is still in the
/// "What for" field it was typed into, so the assertion passes on a bill that
/// never changed, and the failure lands on the other device naming the wrong
/// thing.
Future<void> _expenseWritten(WidgetTester tester) async {
  await pumpUntil(
    tester,
    () => !tester.any(find.byKey(const Key('splits_amount'))),
    description: 'the add-expense screen to close on a written expense',
    timeout: const Duration(minutes: 1),
  );
}

Future<void> _addWithFigures(
  WidgetTester tester,
  String what,
  String amount,
  String chip,
  List<String> values,
) async {
  await _tapText(tester, 'Add expense');
  await _typeInto(tester, 'What was it for?', what);
  await tester.enterText(find.byKey(const Key('splits_amount')), amount);
  await tester.pump();
  await _revealChip(tester, chip);
  await _tapKey(tester, chip);
  final figures = _figureKeys(tester);
  expect(
    figures.length,
    values.length,
    reason: 'one field per person, for $chip',
  );
  for (var i = 0; i < values.length; i++) {
    await tester.enterText(find.byKey(figures[i]), values[i]);
  }
  await tester.pump();
  await _settle(tester);
  expect(find.byKey(const Key('splits_split_refusal')), findsNothing);
  await _tapText(tester, 'Add');
  await _settle(tester);
  await _expenseWritten(tester);
  await _reveal(tester, find.text(what), 'the expense "$what" on the bill');
  expect(find.text(what), findsWidgets);
}

/// The per-person figure fields on screen, in the order they are rendered.
///
/// A participant's id is the one its own device's key derives (§10.7), so the
/// keys cannot be written down here — they are read off the tree instead.
List<Key> _figureKeys(WidgetTester tester) => tester
    .widgetList<Widget>(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('splits_figure_'),
      ),
    )
    .map((w) => w.key!)
    .toList();

/// Widget keys on screen that begin with [prefix], in render order.
///
/// A participant's id is the one its own device's key derives (§10.7), so a
/// key naming one cannot be written down here — it is read off the tree.
List<Key> _keysWithPrefix(WidgetTester tester, String prefix) => tester
    .widgetList<Widget>(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(prefix),
      ),
    )
    .map((w) => w.key!)
    .toList();

/// Reveals a chip in the horizontal list the split kinds live in.
///
/// `add_expense_screen.dart` puts them in one horizontally scrolling row. A
/// chip past the edge is built but off screen, where a tap lands on nothing,
/// so the row is scrolled until the chip is in view.
Future<void> _revealChip(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  expect(target, findsOneWidget, reason: 'the $key chip in the row');
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 150));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await _reveal(tester, find.text(text), 'the control "$text"');
  await tester.tap(find.text(text).last);
  await _settle(tester);
}

/// Brings [target] into the tree, scrolling if it is past the fold.
///
/// The expense form grows as a split is described — five items and a service
/// charge put its submit button well below the screen — and a `ListView` does
/// not build what is not near the viewport. Which scrollable to drive cannot
/// be named in advance either: the split kinds are their own horizontal list
/// inside the vertical one, so each is tried in turn.
Future<void> _reveal(WidgetTester tester, Finder target, String what) async {
  if (tester.any(target)) return;
  final scrollables = find.byType(Scrollable);
  for (var i = 0; i < tester.widgetList(scrollables).length; i++) {
    try {
      await tester.scrollUntilVisible(
        target,
        120,
        scrollable: scrollables.at(i),
        maxScrolls: 30,
      );
      await _settle(tester);
      if (tester.any(target)) return;
    } on Object {
      // That scrollable does not contain it; the next one might.
    }
  }
  await pumpUntil(tester, () => tester.any(target), description: what);
}

const _billMenuItems = {
  'splits_bill_people',
  'splits_bill_activity',
  'splits_bill_payout',
  'splits_bill_price',
  'splits_bill_sync_now',
  'splits_bill_forget',
};

Future<void> _tapKey(WidgetTester tester, String key) async {
  // People, Activity, How you get paid, Price, Sync now and Remove sit in
  // the bill screen's menu, which is opened first when one is asked for.
  if (_billMenuItems.contains(key) && !tester.any(find.byKey(Key(key)))) {
    await tester.tap(find.byKey(const Key('splits_bill_menu')));
    await _settle(tester);
  }
  // A keyboard still opening moves the fold, so it finishes first; then the
  // control is scrolled fully into view before the tap.
  await _settle(tester);
  await pumpUntil(
    tester,
    () => tester.any(find.byKey(Key(key))),
    description: 'the control $key',
  );
  await tester.ensureVisible(find.byKey(Key(key)).last);
  await _settle(tester);
  await tester.tap(find.byKey(Key(key)).last);
  await _settle(tester);
}

Future<void> _typeInto(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextFormField, label);
  await pumpUntil(
    tester,
    () => tester.any(field),
    description: 'the field "$label"',
  );
  await tester.enterText(field.first, text);
  await tester.pump();
}

Future<void> _back(WidgetTester tester) async {
  await tester.pageBack();
  await _settle(tester);
}
