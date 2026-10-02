/// Every field note and refusal on the bill, price and expense forms is read
/// whole on a narrow phone at large text, in the wallet's theme and fonts.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/theme/legacy_material_theme.dart';
import 'package:zcash_wallet/src/features/splits/splits_theme.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

Future<void> _loadFonts() async {
  const families = <String, List<String>>{
    'Geist': ['Geist-Regular', 'Geist-Medium', 'Geist-SemiBold', 'Geist-Bold'],
    'Inter': ['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold', 'Inter-Bold'],
  };
  for (final e in families.entries) {
    final loader = FontLoader(e.key);
    for (final f in e.value) {
      final bytes = File('assets/fonts/$f.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }
}

Widget _themed(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(
    theme: buildLegacyLightTheme(),
    builder: (ctx, child) => AppTheme(
      data: AppThemeData.light,
      child: MediaQuery(
        data: MediaQuery.of(
          ctx,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
    ),
    home: Builder(
      builder: (ctx) =>
          Theme(data: splitsTheme(Theme.of(ctx), ctx.colors), child: home),
    ),
  ),
);

/// Every helper and refusal the fields on screen show, each with whether its
/// paragraph was cut short.
Map<String, bool> _notes(WidgetTester t) {
  final notes = <String, bool>{};
  for (final field in t.widgetList<TextField>(find.byType(TextField))) {
    // A refusal is drawn in place of the note.
    final note = field.decoration?.errorText ?? field.decoration?.helperText;
    if (note == null) continue;
    {
      notes[note] = t
          .renderObject<RenderParagraph>(
            find
                .byWidgetPredicate(
                  (w) => w is RichText && w.text.toPlainText() == note,
                )
                .first,
          )
          .didExceedMaxLines;
    }
  }
  return notes;
}

void _readWhole(WidgetTester t, {required int atLeast}) {
  final notes = _notes(t);
  debugPrint('notes: $notes');
  expect(notes.length, greaterThanOrEqualTo(atLeast));
  expect([
    for (final MapEntry(:key, :value) in notes.entries)
      if (value) key,
  ], isEmpty);
}

Future<(SplitsController, String)> _bill() async {
  final c = SplitsController(
    wallet: FakeWallet(),
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  );
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  await c.addPerson(billId: id, id: 'ben', name: 'Ben');
  return (c, id);
}

void main() {
  setUpAll(_loadFonts);

  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(320 * 3, 874 * 3);
    view.devicePixelRatio = 3;
  });
  tearDown(
    () => TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .reset(),
  );

  testWidgets('a new bill: the currency note and both refusals', (t) async {
    late SplitsController c;
    await t.runAsync(() async => (c, _) = await _bill());
    await t.pumpWidget(_themed(c, const NewBillScreen()));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextFormField, 'USD'), 'ABC');
    await t.tap(find.byKey(const Key('splits_new_bill_open')));
    await t.pumpAndSettle();
    _readWhole(t, atLeast: 2);
    expect(_notes(t), contains('ABC is not a currency this wallet can split'));
  });

  testWidgets('a price: its refusal', (t) async {
    late SplitsController c;
    late String id;
    await t.runAsync(() async => (c, id) = await _bill());
    await t.pumpWidget(_themed(c, PriceBillScreen(billId: id)));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextFormField).first, '0');
    await t.tap(find.byKey(const Key('splits_price_apply')));
    await t.pumpAndSettle();
    _readWhole(t, atLeast: 1);
  });

  testWidgets('an expense: the amount refusal', (t) async {
    late SplitsController c;
    late String id;
    await t.runAsync(() async => (c, id) = await _bill());
    await t.pumpWidget(_themed(c, AddExpenseScreen(billId: id)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_expense_save')));
    await t.pumpAndSettle();
    _readWhole(t, atLeast: 1);
    expect(_notes(t), contains('Enter an amount like 12.50'));
  });

  testWidgets('an itemised expense: the tax note and a cost refusal', (
    t,
  ) async {
    late SplitsController c;
    late String id;
    await t.runAsync(() async => (c, id) = await _bill());
    await t.pumpWidget(_themed(c, AddExpenseScreen(billId: id)));
    await t.pumpAndSettle();
    final itemized = find.byKey(const Key('splits_split_itemized'));
    await t.ensureVisible(itemized);
    await t.tap(itemized);
    await t.pumpAndSettle();
    final add = find.byKey(const Key('splits_item_add'));
    await t.ensureVisible(add);
    await t.tap(add);
    await t.pumpAndSettle();
    final cost = find.byKey(const Key('splits_item_cost_0'));
    await t.ensureVisible(cost);
    await t.enterText(cost, '1.2.3');
    t.state<FormState>(find.byType(Form)).validate();
    await t.pumpAndSettle();
    await t.ensureVisible(cost);
    await t.pumpAndSettle();
    _readWhole(t, atLeast: 1);
    expect(_notes(t), contains('Enter an amount like 12.50'));

    final tax = find.byKey(const Key('splits_item_extra'));
    await t.ensureVisible(tax);
    await t.pumpAndSettle();
    _readWhole(t, atLeast: 1);
    expect(_notes(t), contains('Split in proportion to what each person had'));
  });
}
