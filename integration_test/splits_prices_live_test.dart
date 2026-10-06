/// The live ZEC price sources, from the device and inside the running app.
///
/// Binance's ZECUSDC ticker is the wallet's price and its 24h change, and
/// Coinbase stands behind it; splits bills price USD from Binance and every
/// other currency from Coinbase. This runs them over the device's own network:
/// the sources on their own, the home screen's feed once the app is up, and a
/// new bill that the settle screen prices from that feed without being asked.
///
///     flutter test integration_test/splits_prices_live_test.dart -d <device> \
///       --dart-define=VIZOR_FORM_FACTOR=mobile \
///       --dart-define=ZCASH_DEFAULT_NETWORK=regtest
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/core/config/swap_feature_config.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/splits/splits_prices.dart';
import 'package:zcash_wallet/src/providers/zec_price_change_provider.dart';

import 'support/mobile_regtest_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('prices, live', (tester) async {
    tolerateRenderOverflows();
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) return;
      defaultHandler?.call(details);
    };

    // 1 · Each source, over this device's network.
    final binance = await BinanceZecMarketDataSource().fetchMarketData();
    expect(binance, isNotNull, reason: 'Binance answered the ZECUSDC ticker');
    expect(binance!.change24hPct, isNotNull, reason: 'with a 24h change');
    final coinbase = await CoinbaseZecMarketDataSource().fetchMarketData();
    expect(coinbase, isNotNull, reason: 'Coinbase answered its spot price');
    logE2e(
      'binance ZECUSDC ${binance.usdPrice} (${binance.change24hPct}% 24h), '
      'coinbase ZEC-USD ${coinbase!.usdPrice}',
    );
    // Two markets for one asset: far apart means one is not what it claims.
    final gap =
        (binance.usdPrice - coinbase.usdPrice).abs() / coinbase.usdPrice;
    expect(gap, lessThan(0.03), reason: 'the two USD prices agree within 3%');

    // 2 · The splits chain, with no wallet feed behind it.
    final splits = splitsZecPrices(http: NetworkHttpClient());
    final usd = await splits.minorUnitsPerZec('USD');
    final kes = await splits.minorUnitsPerZec('KES');
    final eur = await splits.minorUnitsPerZec('EUR');
    logE2e('splits: USD $usd, KES $kes, EUR $eur (minor units per ZEC)');
    expect(usd, isNotNull, reason: 'USD, from Binance and Coinbase agreeing');
    expect(kes, isNotNull, reason: 'KES, from Coinbase');
    expect(eur, isNotNull, reason: 'EUR, from Coinbase');
    // The splits figure is Coinbase's /v2/exchange-rates answer; the one
    // above is its /v2/prices/ZEC-USD/spot, a different quantity that moves
    // separately. They are held to the 200 basis points AgreeingZecPrices
    // allows between two markets, not to the cent.
    final spotCents = (coinbase.usdPrice * 100).round();
    expect(
      (usd! - spotCents).abs() * 10000,
      lessThanOrEqualTo(spotCents * 200),
      reason: 'the splits USD figure is Coinbase\'s, within 2% of its spot',
    );

    // 3 · The app's own feed, as the home screen reads it. The wallet runs it
    //     only where swaps are enabled, which is mainnet.
    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await createWalletWithPasscode(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    if (container.read(swapFeatureEnabledProvider)) {
      await pumpUntil(
        tester,
        () => container.read(zecHomeMarketDataProvider)?.change24hPct != null,
        description: 'the home feed, with a 24h change only Binance gives',
        timeout: const Duration(minutes: 2),
      );
      final home = container.read(zecHomeMarketDataProvider)!;
      logE2e('home feed: ${home.usdPrice} (${home.change24hPct}% 24h)');
      expect(home.usdPrice, greaterThan(0));
    } else {
      logE2e('home feed: off on this network, as the wallet runs it');
    }

    // 4 · A new bill in KES, priced by the settle screen from the feed.
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/splits');
    await tester.pumpAndSettle(const Duration(seconds: 10));
    await _tap(tester, find.text('Start a bill'));
    await _type(tester, 'What is it for', 'Priced');
    await _type(tester, 'Currency', 'KES');
    await _tap(tester, find.byKey(const Key('splits_new_bill_open')));
    await _tap(tester, find.text('Settle up'));
    await pumpUntil(
      tester,
      () =>
          tester.any(find.byKey(const Key('splits_settle_owe_nothing'))) ||
          tester.any(find.text('This bill has no price on it yet.')),
      description: 'the settle screen to price the bill or say it cannot',
      timeout: const Duration(minutes: 1),
    );
    expect(
      find.text('This bill has no price on it yet.'),
      findsNothing,
      reason: 'a KES bill is priced from the live feed without asking',
    );
    logE2e('a KES bill was priced from the live feed');
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await pumpUntil(
    tester,
    () => tester.any(target),
    description: '$target',
    timeout: const Duration(seconds: 60),
  );
  await tester.ensureVisible(target.last);
  await tester.pumpAndSettle();
  await tester.tap(target.last);
  await tester.pumpAndSettle(const Duration(seconds: 2));
}

Future<void> _type(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextFormField, label);
  await pumpUntil(
    tester,
    () => tester.any(field),
    description: 'the field "$label"',
  );
  await tester.enterText(field.first, text);
  await tester.pump();
}
