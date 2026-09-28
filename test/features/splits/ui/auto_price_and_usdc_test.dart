import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps;

SplitsController controllerFor({
  ZecPrices prices = const NoZecPrices(),
  SwapProvider? swaps,
}) => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
  prices: prices,
  swaps: swaps ?? FakeSwaps(),
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

/// A bill in [currency] on which this device owes Ben, with no price on it.
Future<String> unpricedBill(SplitsController c, String currency) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: currency))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
    entries.addExpense(
      host: ben,
      expenseId: 'x1',
      paidBy: 'ben',
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': [c.me, 'ben']..sort(),
      },
    ),
  ]);
  expect(c.lastError, isNull);
  expect(c.bills.single.bill.rate, isNull);
  return id;
}

void main() {
  group('settling prices the bill itself', () {
    testWidgets('an unpriced bill takes the live price and offers the send', (
      t,
    ) async {
      final c = controllerFor(prices: const FixedZecPrices({'USD': 5012}));
      final id = await unpricedBill(c, 'USD');

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      final rate = c.bills.single.bill.rate;
      expect(rate?.minorUnitsPerZec, 5012);
      expect(rate?.source, 'feed');
      expect(find.text('Price it'), findsNothing);
      expect(find.byKey(const Key('splits_settle_send')), findsOneWidget);
    });

    testWidgets('with no live price in its currency it asks, and invents '
        'none', (t) async {
      final c = controllerFor(prices: const FixedZecPrices({'USD': 5012}));
      final id = await unpricedBill(c, 'EUR');

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(c.bills.single.bill.rate, isNull);
      expect(find.text('Price it'), findsOneWidget);
      expect(find.byKey(const Key('splits_settle_send')), findsNothing);
    });
  });

  group('being paid in USDC', () {
    const usdc = [
      TradableAsset(
        assetId: 'eth-usdc',
        symbol: 'USDC',
        chain: 'eth',
        decimals: 6,
      ),
      TradableAsset(
        assetId: 'base-usdc',
        symbol: 'USDC',
        chain: 'base',
        decimals: 6,
      ),
      // Listed twice on one chain: which one a payout meant cannot be told.
      TradableAsset(
        assetId: 'hl-a',
        symbol: 'USDC',
        chain: 'hypercore',
        decimals: 8,
      ),
      TradableAsset(
        assetId: 'hl-b',
        symbol: 'USDC',
        chain: 'hypercore',
        decimals: 6,
      ),
      TradableAsset(
        assetId: 'base-eth',
        symbol: 'ETH',
        chain: 'base',
        decimals: 18,
      ),
    ];

    testWidgets('the chains offered are the provider\'s, one USDC each', (
      t,
    ) async {
      final c = controllerFor(swaps: FakeSwaps(assets: usdc));
      final id = await unpricedBill(c, 'USD');
      await t.pumpWidget(app(c, PayoutScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_swap')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_payout_chain_eth')), findsOneWidget);
      expect(find.byKey(const Key('splits_payout_chain_base')), findsOneWidget);
      expect(
        find.byKey(const Key('splits_payout_chain_hypercore')),
        findsNothing,
      );
      expect(find.text('USDC on Base'), findsOneWidget);
      // Nothing is typed while the provider can say where USDC arrives.
      expect(find.byKey(const Key('splits_payout_asset')), findsNothing);
    });

    testWidgets('a picked chain is saved as USDC on that chain', (t) async {
      final c = controllerFor(swaps: FakeSwaps(assets: usdc));
      final id = await unpricedBill(c, 'USD');
      await t.pumpWidget(app(c, PayoutScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_swap')));
      await t.pumpAndSettle();

      await t.dragUntilVisible(
        find.byKey(const Key('splits_payout_chain_base')),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await t.tap(find.byKey(const Key('splits_payout_chain_base')));
      await t.pumpAndSettle();
      await t.dragUntilVisible(
        find.byKey(const Key('splits_payout_address')),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await t.enterText(find.byKey(const Key('splits_payout_address')), '0xme');
      await t.tap(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();

      final me = c.bills.single.bill.participant(c.me)!;
      expect(me.payouts.single.type, 'swap');
      expect(me.payouts.single.asset, 'USDC');
      expect(me.payouts.single.chain, 'base');
      expect(me.payouts.single.address, '0xme');
    });

    testWidgets('no chain picked, nothing saved', (t) async {
      final c = controllerFor(swaps: FakeSwaps(assets: usdc));
      final id = await unpricedBill(c, 'USD');
      await t.pumpWidget(app(c, PayoutScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_swap')));
      await t.pumpAndSettle();
      await t.dragUntilVisible(
        find.byKey(const Key('splits_payout_address')),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await t.enterText(find.byKey(const Key('splits_payout_address')), '0xme');
      await t.tap(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();

      expect(c.bills.single.bill.participant(c.me)!.payouts, isEmpty);
    });
  });

  group('adding an address for somebody', () {
    /// A priced bill on which this device owes Eve, who was added by name
    /// and has shared no address.
    Future<String> owingEve(SplitsController c) async {
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      final eve = otherHost('eve');
      await c.accept(id, [
        entries.joinBill(host: eve, name: 'Eve'),
        entries.addExpense(
          host: eve,
          expenseId: 'x1',
          paidBy: 'eve',
          amount: 2000,
          split: <String, dynamic>{
            'type': 'equal',
            'among': [c.me, 'eve']..sort(),
          },
        ),
      ]);
      await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
      return id;
    }

    testWidgets('an address added on the settle screen makes them payable', (
      t,
    ) async {
      final c = controllerFor();
      final id = await owingEve(c);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.text('You → Eve'), findsOneWidget);
      expect(find.byKey(const Key('splits_settle_send')), findsNothing);

      await t.tap(find.byKey(const Key('splits_settle_add_address_eve')));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const Key('splits_settle_address_field')),
        'zcash:u1eve?amount=1',
      );
      await t.tap(find.byKey(const Key('splits_settle_address_save')));
      await t.pumpAndSettle();

      expect(c.lastError, isNull);
      expect(
        c.bills.single.bill.participant('eve')!.payableAddress,
        'u1eve',
      );
      expect(find.byKey(const Key('splits_settle_send')), findsOneWidget);
    });

    testWidgets('somebody who joined from their own phone sets their own', (
      t,
    ) async {
      final c = controllerFor();
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      final ben = await SignedPeer.named('ben');
      await c.accept(id, [await ben.join(id, name: 'Ben', payTo: '')]);
      await c.setAddressFor(billId: id, id: ben.id, address: 'u1other');
      expect(c.lastError, contains('sets their own address'));
      expect(
        c.bills.single.bill.participant(ben.id)!.payableAddress,
        isNot('u1other'),
      );
    });
  });
}
