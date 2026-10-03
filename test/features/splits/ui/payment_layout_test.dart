/// The payment screens on narrow phones at large text, in the wallet's own
/// theme and fonts: whether a field's note is read whole, and whether a
/// refusal goes once what it asked for is done.
library;

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

import 'support/fake_wallet.dart';

class _Swaps implements SwapProvider {
  static const chains = [
    'eth', 'base', 'arb', 'sol', 'near', 'pol', 'op', 'avax', 'bsc', //
    'gnosis', 'bera', 'ton', 'tron', 'sui', 'aptos', 'stellar', 'xlayer',
    'monad',
  ];

  @override
  Future<List<TradableAsset>> tradableAssets() async => [
    nativeZec,
    for (final c in chains)
      TradableAsset(assetId: '$c-usdc', symbol: 'USDC', chain: c, decimals: 6),
  ];

  @override
  Future<SwapQuote> quote({
    required TradableAsset asset,
    required int amountInZatoshi,
    required String recipient,
    required String refundTo,
  }) => throw UnimplementedError();

  @override
  Future<SwapStatus> statusOf(SwapQuote quote) => throw UnimplementedError();
}

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

Widget _themed(SplitsController c, Widget home, double scale) => SplitsScope(
  controller: c,
  child: MaterialApp(
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

/// A bill on which this device owes ben, who asked for cash.
Future<(SplitsController, String)> _bill() async {
  final c = SplitsController(
    wallet: FakeWallet(),
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
    swaps: _Swaps(),
  );
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(
      host: ben,
      name: 'ben',
      payouts: [
        {'type': 'cash'},
      ],
    ),
    entries.addExpense(
      host: ben,
      expenseId: 'x1',
      paidBy: 'ben',
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['ben', c.me]..sort(),
      },
    ),
  ]);
  return (c, id);
}

/// Whether the paragraph showing exactly [text] was cut short.
bool _cut(WidgetTester t, String text) => t
    .renderObject<RenderParagraph>(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == text,
      ),
    )
    .didExceedMaxLines;

const _helper =
    "The provider's id for the swap, or the transaction on the other chain — "
    'not a Zcash txid';
const _refusal = 'A swap nobody can look up is a swap nobody can check';

final _vertical = find.byWidgetPredicate(
  (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
);

Future<void> _reveal(WidgetTester t, Finder f) async {
  if (f.evaluate().isEmpty) {
    await t.scrollUntilVisible(f, 60, scrollable: _vertical.first);
  }
  await t.ensureVisible(f);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(_loadFonts);

  for (final width in [320.0, 375.0, 393.0, 402.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('the swap reference note and its refusal are read whole, '
          '${width.toInt()} wide at ${scale}x', (t) async {
        t.view.physicalSize = Size(width * 3, 874 * 3);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        late SplitsController c;
        late String id;
        await t.runAsync(() async => (c, id) = await _bill());
        await t.pumpWidget(
          _themed(
            c,
            RecordPaymentScreen(billId: id, to: 'ben', suggestedMinorUnits: 1),
            scale,
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('splits_record_swap')));
        await t.pumpAndSettle();
        expect(_cut(t, 'Swap reference'), isFalse);
        expect(_cut(t, _helper), isFalse);
        await t.tap(find.byKey(const Key('splits_record_save')));
        await t.pumpAndSettle();
        expect(_cut(t, _refusal), isFalse);
      });
    }
  }

  for (final typed in ['', 'not-an-address']) {
    testWidgets('a payout address refused at 320 wide and 2x is read whole '
        '("$typed")', (t) async {
      t.view.physicalSize = const Size(320 * 3, 874 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      late SplitsController c;
      late String id;
      await t.runAsync(() async => (c, id) = await _bill());
      await t.pumpWidget(_themed(c, PayoutScreen(billId: id), 2.0));
      await t.pumpAndSettle();
      await _reveal(t, find.byKey(const Key('splits_payout_swap')));
      await t.tap(find.byKey(const Key('splits_payout_swap')));
      await t.pumpAndSettle();
      final base = find.byKey(const Key('splits_payout_chain_base'));
      await _reveal(t, base);
      await t.tap(base);
      await t.pumpAndSettle();
      final address = find.byKey(const Key('splits_payout_address'));
      await _reveal(t, address);
      await t.enterText(address, typed);
      await t.tap(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();
      await _reveal(t, address);
      final field = t.widget<TextField>(
        find.descendant(of: address, matching: find.byType(TextField)),
      );
      final said = field.decoration?.errorText;
      debugPrint('refused "$typed": $said');
      expect(said, isNotNull);
      expect(_cut(t, said!), isFalse);
    });
  }

  for (final (w, h, scale) in [
    (320.0, 568.0, 1.0),
    (320.0, 568.0, 2.0),
    (375.0, 667.0, 2.0),
  ]) {
    final tag = '${w.toInt()}x${h.toInt()} at ${scale}x';

    testWidgets('picking a chain clears the ask for one, and the address '
        'being typed stays in view, $tag', (t) async {
      t.view.physicalSize = Size(w * 3, h * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      late SplitsController c;
      late String id;
      await t.runAsync(() async => (c, id) = await _bill());
      await t.pumpWidget(_themed(c, PayoutScreen(billId: id), scale));
      await t.pumpAndSettle();
      await _reveal(t, find.byKey(const Key('splits_payout_swap')));
      await t.tap(find.byKey(const Key('splits_payout_swap')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();
      expect(find.text('Pick the chain you want USDC on.'), findsOneWidget);
      final monad = find.byKey(const Key('splits_payout_chain_monad'));
      await _reveal(t, monad);
      await t.tap(monad);
      await t.pumpAndSettle();
      expect(find.text('Pick the chain you want USDC on.'), findsNothing);
      final address = find.byKey(const Key('splits_payout_address'));
      await _reveal(t, address);
      await t.tap(address, warnIfMissed: false);
      await t.pump();
      t.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
      addTearDown(t.view.resetViewInsets);
      await t.pumpAndSettle();
      final body = t.getRect(find.byType(ListView).first);
      final field = t.getRect(address);
      expect(field.top, greaterThanOrEqualTo(body.top - 0.5));
      expect(field.bottom, lessThanOrEqualTo(body.bottom + 0.5));
    });

    testWidgets('typing an address clears the ask for one, $tag', (t) async {
      t.view.physicalSize = Size(w * 3, h * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      late SplitsController c;
      late String id;
      await t.runAsync(() async => (c, id) = await _bill());
      await t.pumpWidget(_themed(c, PayoutScreen(billId: id), scale));
      await t.pumpAndSettle();
      await _reveal(t, find.byKey(const Key('splits_payout_swap')));
      await t.tap(find.byKey(const Key('splits_payout_swap')));
      await t.pumpAndSettle();
      final base = find.byKey(const Key('splits_payout_chain_base'));
      await _reveal(t, base);
      await t.tap(base);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();
      expect(
        find.text('Nobody can be paid without an address.'),
        findsOneWidget,
      );
      final address = find.byKey(const Key('splits_payout_address'));
      await _reveal(t, address);
      await t.enterText(address, '0x52908400098527886E0F7030069857D2E4169EE7');
      await t.pumpAndSettle();
      expect(find.text('Nobody can be paid without an address.'), findsNothing);
    });
  }

  testWidgets('a refusal stays while nothing it asked for is done', (t) async {
    late SplitsController c;
    late String id;
    await t.runAsync(() async => (c, id) = await _bill());
    await t.pumpWidget(_themed(c, PayoutScreen(billId: id), 1.0));
    await t.pumpAndSettle();
    await _reveal(t, find.byKey(const Key('splits_payout_swap')));
    await t.tap(find.byKey(const Key('splits_payout_swap')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_payout_save')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_payout_save')));
    await t.pumpAndSettle();
    expect(find.text('Pick the chain you want USDC on.'), findsOneWidget);
  });

  testWidgets('payout-for: typing an address clears the ask for one', (
    t,
  ) async {
    late SplitsController c;
    late String id;
    await t.runAsync(() async => (c, id) = await _bill());
    await c.addPerson(billId: id, id: 'dee', name: 'dee');
    await t.pumpWidget(
      _themed(c, PayoutForScreen(billId: id, id: 'dee', name: 'dee'), 1.0),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_address_save')));
    await t.pumpAndSettle();
    expect(find.text('Nobody can be paid without an address.'), findsOneWidget);
    await t.enterText(
      find.byKey(const Key('splits_address_field')),
      'u1deepayable0000000001',
    );
    await t.pumpAndSettle();
    expect(find.text('Nobody can be paid without an address.'), findsNothing);
  });
}
