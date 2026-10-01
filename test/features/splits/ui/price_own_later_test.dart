// The organiser told how to reprice a bill their own later-dated price
// still holds.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(5)),
  prices: const NoZecPrices(),
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

String? notApplied(WidgetTester t) {
  final f = find.byKey(const Key('splits_price_not_applied'));
  if (f.evaluate().isEmpty) return null;
  return (t.widget(f) as Text).data;
}

Future<void> reprice(WidgetTester t, String figure) async {
  await t.enterText(find.byType(TextFormField), figure);
  await t.tap(find.text('Reprice the bill'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('beaten by their own later price, they can withdraw it', (
    t,
  ) async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    // Priced once with a clock a day ahead, then again with it put right.
    wallet.tick(const Duration(days: 1));
    await c.setRate(billId: id, currency: 'EUR', minorUnitsPerZec: 100);
    wallet.tick(const Duration(days: -2));

    await t.pumpWidget(app(c, PriceBillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_price_withdraw')), findsNothing);
    await reprice(t, '3000');

    expect(c.bills.single.bill.rate!.minorUnitsPerZec, 100);
    expect(notApplied(t), contains('your earlier price'));
    expect(notApplied(t), isNot(contains('Ask the organiser')));
    await t.tap(find.byKey(const Key('splits_price_withdraw')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_price_withdraw_confirm')));
    await t.pumpAndSettle();
    expect(c.lastError, isNull);
    await reprice(t, '3000');
    expect(c.bills.single.bill.rate!.minorUnitsPerZec, 300000);
  });

  testWidgets('with no skew the reprice applies and offers no withdraw', (
    t,
  ) async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    wallet.tick();
    await c.setRate(billId: id, currency: 'EUR', minorUnitsPerZec: 100);
    wallet.tick();
    await t.pumpWidget(app(c, PriceBillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_price_withdraw')), findsNothing);
    await reprice(t, '3000');
    expect(c.bills.single.bill.rate!.minorUnitsPerZec, 300000);
    expect(notApplied(t), isNull);
  });
}
