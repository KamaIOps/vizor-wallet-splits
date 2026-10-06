// The bills screens under the wallet's theme, as splits_entry_screen.dart
// applies it, with the wallet's own fonts: the layout holds at a narrow width
// and a large text size, the actions stay above the keyboard, and the labels
// that carry a choice or a warning stay legible.
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/theme/legacy_material_theme.dart';
import 'package:zcash_wallet/src/features/splits/splits_theme.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'ui/support/fake_wallet.dart';

SplitsController _controller() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

Widget _themed(
  SplitsController c,
  Widget home, {
  required bool dark,
  double scale = 1,
}) => SplitsScope(
  controller: c,
  child: MaterialApp(
    theme: buildLegacyLightTheme(),
    darkTheme: buildLegacyDarkTheme(),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    builder: (ctx, child) => AppTheme(
      data: dark ? AppThemeData.dark : AppThemeData.light,
      child: MediaQuery(
        data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
    home: Builder(
      builder: (ctx) =>
          Theme(data: splitsTheme(Theme.of(ctx), ctx.colors), child: home),
    ),
  ),
);

/// The wallet's fonts, so a line breaks where it does on a phone. Without
/// them every glyph is the test font's square and widths mean nothing.
Future<void> _loadFonts() async {
  const families = <String, List<String>>{
    'Geist': ['Geist-Regular', 'Geist-Medium', 'Geist-SemiBold', 'Geist-Bold'],
    'Young Serif': ['YoungSerif-Regular'],
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

const _longBill =
    'Weekend trip to Thiruvananthapuram with the extended family and friends';
const _longPeer = 'Bartholomew-Alexandros Papadopoulos-Konstantinidis';

/// A bill on which this device owes a peer the most two expenses can carry,
/// priced, so every row that puts a figure beside a name is on screen.
Future<String> _bill(SplitsController c) async {
  await c.load();
  final id = (await c.createBill(name: _longBill, currency: 'EUR'))!;
  final b = await SignedPeer.named('b-peer');
  await c.accept(id, [
    await b.join(id, name: _longPeer, payTo: 'u1bartholomewpayable0000000001'),
    for (final x in ['x1', 'x2'])
      await b.sign(
        entries.addExpense(
          host: b.host,
          expenseId: x,
          paidBy: b.id,
          amount: 92233720368,
          description: 'Houseboat on the backwaters, two nights, all meals',
          split: <String, dynamic>{
            'type': 'equal',
            'among': [c.me],
          },
        ),
        id,
      ),
    await b.sign(
      entries.setRate(host: b.host, currency: 'EUR', minorUnitsPerZec: 100000),
      id,
    ),
  ]);
  expect(c.lastError, isNull);
  expect(c.bills.single.setAside, isEmpty);
  return id;
}

double _luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// WCAG contrast of [fg] on [bg], both composited over [page].
double _contrast(Color fg, Color bg, Color page) {
  Color over(Color top, Color under) => Color.from(
    alpha: 1,
    red: top.r * top.a + under.r * (1 - top.a),
    green: top.g * top.a + under.g * (1 - top.a),
    blue: top.b * top.a + under.b * (1 - top.a),
  );
  final b = over(bg, page);
  final f = over(fg, b);
  final l1 = _luminance(f), l2 = _luminance(b);
  return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05);
}

Color _textColour(WidgetTester t, Finder text) {
  final p = t.renderObject<RenderParagraph>(text);
  Color? found;
  p.text.visitChildren((span) {
    found ??= span.style?.color;
    return found == null;
  });
  return found ?? p.text.style!.color!;
}

void main() {
  setUpAll(_loadFonts);

  for (final dark in [false, true]) {
    testWidgets('a name and its figure both fit at 320 wide and twice the '
        'text size (${dark ? 'dark' : 'light'})', (t) async {
      t.view.physicalSize = const Size(320 * 3, 568 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final c = _controller();
      final id = await _bill(c);

      // Collected, and asserted only once the handler is put back: an expect
      // while it is replaced wedges the binding rather than failing.
      final overflows = <String>[];
      var screen = '';
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.exception.toString();
        if (text.contains('overflowed')) {
          overflows.add('$screen: ${text.split('\n').first}');
          return;
        }
        previous?.call(d);
      };
      try {
        for (final e in <String, Widget>{
          'Bills': const BillsScreen(),
          'Bill': BillScreen(billId: id),
          'Settle': SettleScreen(billId: id),
        }.entries) {
          screen = e.key;
          await t.pumpWidget(_themed(c, e.value, dark: dark, scale: 2));
          await t.pumpAndSettle();
        }
      } finally {
        FlutterError.onError = previous;
      }
      expect(overflows, isEmpty);
    });
  }

  testWidgets('the action a field is filled in for stays above the keyboard', (
    t,
  ) async {
    t.view.physicalSize = const Size(375 * 3, 667 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final c = _controller();
    final id = await _bill(c);
    final payee = c.bills.single.bill.participants
        .firstWhere((p) => p.name == _longPeer)
        .id;
    // A decimal pad and the wallet's Done bar.
    const keyboard = 260.0;
    for (final e in <String, (Widget, String)>{
      'AddExpense': (AddExpenseScreen(billId: id), 'Add'),
      'Record': (RecordPaymentScreen(billId: id, to: payee), 'Record payment'),
      'PriceBill': (PriceBillScreen(billId: id), 'Reprice the bill'),
      'NewBill': (const NewBillScreen(), 'Open the bill'),
      'Scan': (const ScanBillScreen(), 'Join'),
    }.entries) {
      t.view.resetViewInsets();
      await t.pumpWidget(_themed(c, e.value.$1, dark: false));
      await t.pumpAndSettle();
      await t.tap(find.byType(TextField).first);
      t.view.viewInsets = const FakeViewPadding(bottom: keyboard * 3);
      await t.pumpAndSettle();
      final button = t.getRect(find.widgetWithText(FilledButton, e.value.$2));
      expect(
        button.bottom,
        lessThanOrEqualTo(667 - keyboard),
        reason: '${e.key}: "${e.value.$2}" at $button is under the keyboard',
      );
    }
  });

  for (final dark in [false, true]) {
    testWidgets('a selected chip and an error notice read at 4.5:1 '
        '(${dark ? 'dark' : 'light'})', (t) async {
      t.view.physicalSize = const Size(393 * 3, 852 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final c = _controller();
      final id = await _bill(c);
      await t.pumpWidget(_themed(c, AddExpenseScreen(billId: id), dark: dark));
      await t.pumpAndSettle();
      final theme = Theme.of(t.element(find.byType(AddExpenseScreen)));
      final page = theme.scaffoldBackgroundColor;
      final fill = theme.chipTheme.selectedColor!;

      Future<void> expectReadable(Finder chip, String what) async {
        await t.ensureVisible(chip);
        await t.pumpAndSettle();
        final label = find.descendant(
          of: chip,
          matching: find.byType(RichText),
        );
        final ratio = _contrast(_textColour(t, label.first), fill, page);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: '$what: $ratio');
      }

      // A ChoiceChip swaps to its secondary label style when selected; a
      // FilterChip does not, so the two are held to the same bar separately.
      final payer = find
          .byWidgetPredicate(
            (w) => w is ChoiceChip && '${w.key}'.contains('splits_paid_by_'),
          )
          .first;
      await t.tap(payer);
      await t.pumpAndSettle();
      expect(t.widget<ChoiceChip>(payer).selected, isTrue);
      await expectReadable(payer, 'the payer chosen');

      await t.ensureVisible(find.byKey(const Key('splits_split_itemized')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_split_itemized')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('splits_item_add')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_item_add')));
      await t.pumpAndSettle();
      final item = find.byType(FilterChip).first;
      await t.ensureVisible(item);
      await t.pumpAndSettle();
      if (!t.widget<FilterChip>(item).selected) {
        await t.tap(item);
        await t.pumpAndSettle();
      }
      expect(t.widget<FilterChip>(item).selected, isTrue);
      await expectReadable(item, 'a person ticked on an item');

      final s = theme.colorScheme;
      final notice = _contrast(s.onErrorContainer, s.errorContainer, page);
      expect(notice, greaterThanOrEqualTo(4.5), reason: 'error notice $notice');
    });
  }
}
