// The splits screens hosted as the wallet hosts them, with the wallet's
// fonts loaded, for tests that measure what is drawn.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/theme/legacy_material_theme.dart';
import 'package:zcash_wallet/src/features/splits/splits_theme.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import '../../../../figma_compare/figma_compare_font_loader.dart';
import 'fake_wallet.dart';

export 'fake_wallet.dart';

bool _fonts = false;
Future<void> fonts() async {
  if (_fonts) return;
  await loadFigmaCompareFonts();
  _fonts = true;
}

SplitsController controllerWith({
  PreviewSend? preview,
  FakeWallet? wallet,
  ReadsAddress? reads,
}) => SplitsController(
  wallet: wallet ?? FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
  previewSend: preview ?? ((_) async => const SendPreview(feeZatoshi: 10000)),
  readsAddress: reads ?? ((_) async => true),
);

/// The wallet's host: legacy Material theme by mode, AppTheme above every
/// route, and splitsTheme above the navigator.
Widget host(SplitsController c, Widget home, {bool dark = false, Key? key}) =>
    SplitsScope(
      key: key,
      controller: c,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLegacyLightTheme(),
        darkTheme: buildLegacyDarkTheme(),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => AppTheme(
          data: dark ? AppThemeData.dark : AppThemeData.light,
          child: Builder(
            builder: (context) => Theme(
              data: splitsTheme(Theme.of(context), context.colors),
              child: child!,
            ),
          ),
        ),
        home: home,
      ),
    );

typedef Payee = ({String id, String name, String address, int owe});

/// A USD bill where this device owes each payee [Payee.owe] cents, at [rate]
/// cents a ZEC.
Future<String> owing(
  SplitsController c,
  List<Payee> payees, {
  int rate = 100000,
}) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final list = <Map<String, dynamic>>[];
  for (final p in payees) {
    final h = otherHost(p.id);
    list.add(entries.joinBill(host: h, name: p.name, payTo: p.address));
    list.add(
      entries.addExpense(
        host: h,
        expenseId: 'x${p.id}',
        paidBy: p.id,
        amount: p.owe * 2,
        split: <String, dynamic>{
          'type': 'equal',
          'among': [p.id, c.me]..sort(),
        },
      ),
    );
  }
  await c.accept(id, list);
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: rate);
  return id;
}

Future<void> setSize(
  WidgetTester t,
  double width,
  double dpr, {
  double height = 0,
  double scale = 1.0,
}) async {
  final h = height == 0 ? (width < 360 ? 568.0 : 844.0) : height;
  t.view.devicePixelRatio = dpr;
  t.view.physicalSize = Size(width * dpr, h * dpr);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Every overflow error raised while [body] runs.
Future<List<String>> overflows(Future<void> Function() body) async {
  final seen = <String>[];
  final old = FlutterError.onError;
  FlutterError.onError = (d) {
    final s = d.exceptionAsString();
    if (s.contains('overflowed')) {
      seen.add(s.split('\n').first);
    } else {
      old?.call(d);
    }
  };
  try {
    await body();
  } finally {
    FlutterError.onError = old;
  }
  return seen;
}

/// Every paragraph on screen drawn short of its text: ellipsized, or taller
/// than the box it was given.
List<String> cutText(WidgetTester t, {Finder? within}) {
  final out = <String>[];
  final roots = within == null
      ? t.allRenderObjects
      : within.evaluate().expand((e) {
          final r = e.renderObject!;
          final all = <RenderObject>[r];
          void walk(RenderObject o) => o.visitChildren((c) {
            all.add(c);
            walk(c);
          });
          walk(r);
          return all;
        });
  for (final p in roots.whereType<RenderParagraph>()) {
    if (!p.hasSize) continue;
    final text = p.text.toPlainText();
    final need = p.getMaxIntrinsicHeight(p.size.width);
    if (p.didExceedMaxLines) {
      out.add('ELLIPSIZED w=${p.size.width.toStringAsFixed(0)}: "$text"');
    } else if (need > p.size.height + 0.5) {
      out.add(
        'CLIPPED h=${p.size.height.toStringAsFixed(0)} needs '
        '${need.toStringAsFixed(0)}: "$text"',
      );
    }
  }
  return out;
}

Future<void> openReview(WidgetTester t) async {
  await t.tap(find.byKey(const Key('splits_settle_send')));
  await t.pumpAndSettle();
}

/// An address-shaped string of [length] characters from the Bech32 alphabet,
/// fixed by [seed].
String ua(String seed, {int length = 213}) {
  const alphabet = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  final b = StringBuffer('u1');
  var x = seed.codeUnits.fold<int>(7, (a, c) => a * 31 + c);
  while (b.length < length) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    b.write(alphabet[x % 32]);
  }
  return b.toString();
}
