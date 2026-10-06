// The expense form under the wallet's theme and fonts, on a narrow phone at a
// large text size: every figure field shows the whole of what was typed, and
// a chip choosing a person shows what tells two of one name apart.
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

const _sizes = [
  (Size(320, 568), 2.0),
  (Size(375, 667), 1.3),
  (Size(393, 852), 1.0),
];

Widget _themed(SplitsController c, Widget home, double scale) => SplitsScope(
  controller: c,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildLegacyLightTheme(),
    builder: (ctx, child) => AppTheme(
      data: AppThemeData.light,
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

Future<void> _loadFonts() async {
  const families = <String, List<String>>{
    'Geist': ['Geist-Regular', 'Geist-Medium', 'Geist-SemiBold', 'Geist-Bold'],
    'Geist Mono': ['GeistMono-Regular', 'GeistMono-Medium'],
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

Future<void> _reach(WidgetTester t, Finder f, {bool up = false}) async {
  await t.scrollUntilVisible(
    f,
    up ? -150 : 150,
    scrollable: find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await t.pumpAndSettle();
}

/// How wide [field]'s text is laid out against how wide its box is.
(double, double) _fit(WidgetTester t, Finder field) {
  final r = t
      .state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .renderEditable;
  return (r.getMaxIntrinsicWidth(double.infinity), r.size.width);
}

SplitsController _controller() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

void _phone(WidgetTester t, Size size) {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

void main() {
  setUpAll(_loadFonts);

  for (final (size, scale) in _sizes) {
    final tag = '${size.width.toInt()}@$scale';

    testWidgets('a typed figure shows whole at $tag', (t) async {
      _phone(t, size);
      final c = _controller();
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
        await c.addPerson(billId: id, id: 'ben', name: 'Ben');
      });
      await t.pumpWidget(_themed(c, AddExpenseScreen(billId: id), scale));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('splits_amount')), '1250.75');

      await _reach(t, find.byKey(const Key('splits_split_exact')));
      await t.tap(find.byKey(const Key('splits_split_exact')));
      await t.pumpAndSettle();
      final share = find.byKey(const Key('splits_figure_ben'));
      await _reach(t, share);
      await t.enterText(share, '1000.75');
      await t.pumpAndSettle();
      final (shareText, shareBox) = _fit(t, share);
      expect(shareText, lessThanOrEqualTo(shareBox), reason: 'exact share');

      await _reach(t, find.byKey(const Key('splits_split_itemized')), up: true);
      await t.tap(find.byKey(const Key('splits_split_itemized')));
      await t.pumpAndSettle();
      await _reach(t, find.byKey(const Key('splits_item_add')));
      await t.tap(find.byKey(const Key('splits_item_add')));
      await t.pumpAndSettle();
      final cost = find.byKey(const Key('splits_item_cost_0'));
      await _reach(t, cost);
      await t.enterText(cost, '1250.75');
      await t.pumpAndSettle();
      final (costText, costBox) = _fit(t, cost);
      expect(costText, lessThanOrEqualTo(costBox), reason: 'item cost');
      expect(t.takeException(), isNull);
    });

    for (final name in const [
      'Priyanka Venkataraghavan-Iyer',
      'Priyanka Venkataraghavan-Iyer Subramaniam',
    ]) {
      testWidgets('two people called $name tell apart on a chip at $tag', (
        t,
      ) async {
        _phone(t, size);
        final c = _controller();
        late String id;
        late SignedPeer other;
        await t.runAsync(() async {
          await c.load();
          id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
          await c.addPerson(billId: id, id: 'priyanka', name: name);
          other = await SignedPeer.named('imposter');
          await c.accept(id, [await other.join(id, name: name, payTo: 'u1x')]);
        });
        final view = c.bills.single;
        final ids = ['priyanka', other.id];
        final full = [
          for (final p in ids)
            view.bill.displayNameOf(p, creatorId: view.creatorId),
        ];
        expect(full[0], isNot(full[1]));

        await t.pumpWidget(_themed(c, AddExpenseScreen(billId: id), scale));
        await t.pumpAndSettle();
        await _reach(t, find.byKey(const Key('splits_split_itemized')));
        await t.tap(find.byKey(const Key('splits_split_itemized')));
        await t.pumpAndSettle();
        await _reach(t, find.byKey(const Key('splits_item_add')));
        await t.tap(find.byKey(const Key('splits_item_add')));
        await t.pumpAndSettle();

        for (final key in [
          for (final p in ids) 'splits_paid_by_$p',
          for (final p in ids) 'splits_item_0_$p',
        ]) {
          final chip = find.byKey(Key(key));
          await _reach(t, chip);
          final label = t.renderObject<RenderParagraph>(
            find.descendant(of: chip, matching: find.byType(RichText)).first,
          );
          final text = label.text.toPlainText();
          expect(full, contains(text), reason: key);
          // A line cut short lays out no box for the glyphs it drops, so the
          // boxes below cannot see a truncation: the paragraph says so itself.
          expect(label.didExceedMaxLines, isFalse, reason: '$key: cut short');
          // Every glyph, the qualifier at the end included, is laid out
          // inside the label, and the label inside its chip.
          final boxes = label.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: text.length),
          );
          expect(boxes, isNotEmpty, reason: key);
          for (final b in boxes) {
            expect(
              b.right,
              lessThanOrEqualTo(label.size.width + 0.5),
              reason: '$key: $b in ${label.size}',
            );
            expect(
              b.bottom,
              lessThanOrEqualTo(label.size.height + 0.5),
              reason: '$key: $b in ${label.size}',
            );
          }
          final shown = label.localToGlobal(Offset.zero) & label.size;
          final box = t.getRect(chip);
          expect(
            box.inflate(0.5).contains(shown.topLeft) &&
                box.inflate(0.5).contains(shown.bottomRight),
            isTrue,
            reason: '$key: $shown in $box',
          );
        }
        expect(t.takeException(), isNull);
      });
    }
  }
}
