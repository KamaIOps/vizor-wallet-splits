/// Every money figure on the splits screens stays on one line at 320 points
/// wide and twice the text size: a line may break between words, never inside
/// the digits.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/theme/legacy_material_theme.dart';
import 'package:zcash_wallet/src/features/splits/splits_theme.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'entry_join_test.dart' show splitFigures;
import 'support/fake_wallet.dart';
import 'support/closing.dart';

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
    key: UniqueKey(),
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

/// Priyanka paid the largest expense one entry may carry, shared with this
/// device; this device recorded paying her most of it, and she recorded a
/// payment to it. Priced, so the settle screen has a request to show.
Future<(SplitsController, String)> _bigBill() async {
  final wallet = FakeWallet();
  final c = SplitsController(
    wallet: wallet,
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  );
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
  final priya = await SignedPeer.named('priyanka');
  await c.accept(id, [
    await priya.join(
      id,
      name: 'Priyanka Raghunathan',
      payTo: 'u1priyankapayable00001',
    ),
    await priya.sign(
      entries.addExpense(
        host: priya.host,
        expenseId: 'x1',
        paidBy: priya.id,
        amount: protocol.maxEntryAmount,
        split: <String, dynamic>{
          'type': 'equal',
          'among': [priya.id, c.me]..sort(),
        },
      ),
      id,
    ),
    await priya.sign(
      entries.recordPayment(
        host: priya.host,
        paymentId: 'p1',
        to: c.me,
        amount: 12345678901,
        method: 'cash',
      ),
      id,
    ),
  ]);
  await c.setRate(billId: id, currency: 'EUR', minorUnitsPerZec: 3456789);
  await closeForSettling(c, id);
  wallet.tick();
  await c.recordCash(billId: id, to: priya.id, amountMinorUnits: 12345678901);
  expect(c.lastError, isNull);
  return (c, id);
}

/// [splitFigures] over everything the screen's list builds, scrolled from
/// top to bottom.
Future<Set<String>> _sweep(WidgetTester t, Set<String> seen) async {
  void look() {
    for (final w in t.widgetList<RichText>(find.byType(RichText))) {
      final text = w.text.toPlainText();
      if (RegExp(r'\d{6,}').hasMatch(text)) seen.add(text);
    }
  }

  look();
  final out = <String>{...splitFigures(t)};
  final lists = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
  );
  if (lists.evaluate().isEmpty) return out;
  for (var i = 0; i < 60; i++) {
    final position = t.state<ScrollableState>(lists.first).position;
    if (position.pixels >= position.maxScrollExtent) break;
    await t.drag(lists.first, const Offset(0, -200));
    await t.pumpAndSettle();
    out.addAll(splitFigures(t));
    look();
  }
  return out;
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

  final screens = <String, Widget Function(String id)>{
    'BillsScreen': (_) => const BillsScreen(),
    'BillScreen': (id) => BillScreen(billId: id),
    'SettleScreen': (id) => SettleScreen(billId: id),
    'ActivityScreen': (id) => ActivityScreen(billId: id),
  };

  for (final MapEntry(:key, :value) in screens.entries) {
    testWidgets('$key keeps every figure whole', (t) async {
      late SplitsController c;
      late String id;
      await t.runAsync(() async => (c, id) = await _bigBill());
      await t.pumpWidget(_themed(c, value(id)));
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pumpAndSettle();
      final seen = <String>{};
      final split = await _sweep(t, seen);
      debugPrint('$key split: $split, figures read: ${seen.length}');
      // The probe read figures this long on this screen.
      expect(seen, isNotEmpty);
      expect(split, isEmpty);
      expect(t.takeException(), isNull);
      c.stopPolling();
    });
  }
}
