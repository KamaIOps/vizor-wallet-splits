import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet, {ZecPrices? prices}) =>
    SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(5)),
      prices: prices ?? const NoZecPrices(),
    );

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

void main() {
  test(
    'a build with no feed prices nothing, and says so by answering null',
    () async {
      final c = controllerFor(FakeWallet());
      await c.load();
      expect(await c.quoteZec('EUR'), isNull);
    },
  );

  test('a feed answers in minor units, for the currencies it knows', () async {
    final c = controllerFor(
      FakeWallet(),
      prices: const FixedZecPrices({'EUR': 4567, 'USD': 5012}),
    );
    await c.load();
    expect(await c.quoteZec('EUR'), 4567);
    expect(await c.quoteZec('eur'), 4567, reason: 'the code is not case');
    expect(await c.quoteZec('JPY'), isNull);
  });

  testWidgets('an unpriced bill offers the way to price it', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();

    // Saying "put a rate on it first" with no way through would leave a
    // person reading an instruction they cannot follow.
    expect(find.text('Price it'), findsOneWidget);
    await t.tap(find.text('Price it'));
    await t.pumpAndSettle();
    expect(find.text('Price this bill'), findsOneWidget);
  });

  testWidgets('a price typed in is snapshotted onto the bill', (t) async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;

    await t.pumpWidget(app(c, PriceBillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.textContaining('no price feed'), findsOneWidget);

    await t.enterText(find.byType(TextFormField), '45.67');
    await t.tap(find.text('Put this price on the bill'));
    await t.pumpAndSettle();

    final rate = c.bills.single.bill.rate!;
    expect(rate.minorUnitsPerZec, 4567);
    expect(rate.currency, 'EUR');
    expect(rate.source, 'typed');
  });

  testWidgets('a price from the feed is offered, and marked as the feed\'s', (
    t,
  ) async {
    final c = controllerFor(
      FakeWallet(),
      prices: const FixedZecPrices({'EUR': 4567}),
    );
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;

    await t.pumpWidget(app(c, PriceBillScreen(billId: id)));
    await t.pumpAndSettle();

    expect(find.textContaining('The feed says'), findsOneWidget);
    await t.tap(find.text('Put this price on the bill'));
    await t.pumpAndSettle();

    final rate = c.bills.single.bill.rate!;
    expect(rate.minorUnitsPerZec, 4567);
    expect(
      rate.source,
      'feed',
      reason: 'a reader of the bill should not have to guess',
    );
  });

  testWidgets('a price of nothing is refused in the field', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;

    await t.pumpWidget(app(c, PriceBillScreen(billId: id)));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextFormField), '0');
    await t.tap(find.text('Put this price on the bill'));
    await t.pumpAndSettle();

    // §7 refuses a rate that is not positive, and a bill priced at zero would
    // make every debt cost nothing.
    expect(find.text('A price is more than nothing'), findsOneWidget);
    expect(c.bills.single.bill.rate, isNull);
  });

  testWidgets('pricing a bill makes it settleable, at that figure', (t) async {
    final wallet = FakeWallet();
    final c = controllerFor(
      wallet,
      prices: const FixedZecPrices({'EUR': 51234}),
    );
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;

    // A second person, so there is something to owe.
    final other = FakeWallet(id: 'ben', payTo: 'u1ben');
    other.tick();
    other.tick();
    await c.accept(id, [
      splitz.joinBill(host: WalletBillHost(other), name: 'Ben', payTo: 'u1ben'),
    ]);
    wallet.tick();
    await c.addExpense(
      billId: id,
      paidBy: 'ben',
      amountMinorUnits: 9000,
      among: [c.me, 'ben'],
    );

    expect(await c.obligation(id), isNull, reason: 'not priced yet');

    await t.pumpWidget(app(c, PriceBillScreen(billId: id)));
    await t.pumpAndSettle();
    await t.tap(find.text('Put this price on the bill'));
    await t.pumpAndSettle();

    final owed = (await c.obligation(id))!;
    expect(owed.settlements.single.to, 'ben');
    expect(owed.settlements.single.amount, 4500);
    expect(owed.uri, startsWith('zcash:u1ben'));
  });

  testWidgets('a price dated ahead is not reported as replaced, and the '
      'organiser can withdraw it', (t) async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;

    // Ben, joined from his own device, prices the bill a year ahead: §10.1
    // takes the latest by `at`, so no later reprice outranks it.
    final ben = await SignedPeer.named('ben');
    final ahead = FakeWallet(id: 'ben');
    ahead.tick(const Duration(days: 365));
    final aheadHost = WalletBillHost(ahead, me: ben.id, sign: ben.host.sign);
    await c.accept(id, [
      await ben.join(id, name: 'Ben', payTo: 'u1ben'),
      await splitz.signEntry(
        host: aheadHost,
        entry: splitz.setRate(
          host: aheadHost,
          currency: 'EUR',
          minorUnitsPerZec: 100,
        ),
        billId: id,
      ),
    ]);
    expect(c.bills.single.bill.rate!.minorUnitsPerZec, 100);

    await t.pumpWidget(app(c, PriceBillScreen(billId: id)));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextFormField), '3000');
    await t.tap(find.text('Reprice the bill'));
    await t.pumpAndSettle();

    // Written, not applied, and said so rather than the screen closing.
    expect(find.byType(PriceBillScreen), findsOneWidget);
    expect(find.byKey(const Key('splits_price_not_applied')), findsOneWidget);
    expect(c.bills.single.bill.rate!.minorUnitsPerZec, 100);

    await t.tap(find.byKey(const Key('splits_price_withdraw')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_price_withdraw_confirm')));
    await t.pumpAndSettle();
    expect(c.bills.single.bill.rate!.minorUnitsPerZec, 300000);
    expect(c.bills.single.rateSetBy, c.me);
  });
}
