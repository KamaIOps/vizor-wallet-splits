/// The market behind the splits screens' prices, over real HTTP: a blocked
/// CoinGecko is passed over for Binance on USD and Coinbase on the rest.
library;

import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/splits/splits_prices.dart';
import 'package:zcash_wallet/src/providers/zec_price_change_provider.dart';

/// A wallet feed with no price, so every figure comes from the market.
T Function<T>(ProviderListenable<T>) _noFeed() =>
    <T>(ProviderListenable<T> _) => null as T;

void main() {
  late HttpServer server;
  late Uri origin;
  final asked = <String>[];

  setUp(() async {
    asked.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      asked.add(request.uri.path);
      final response = request.response;
      switch (request.uri.path) {
        case '/gecko/simple/price':
          // What CoinGecko's edge answers a caller it blocks.
          response.statusCode = 403;
          response.write('<HTML><TITLE>ERROR: Request blocked.</TITLE>');
        case '/binance/api/v3/ticker/price':
          response.write('{"symbol":"ZECUSDT","price":"1390.54000000"}');
        case '/coinbase/v2/exchange-rates':
          response.write(
            '{"data":{"currency":"ZEC","rates":'
            '{"USD":"1389.05","KES":"180159.79","EUR":"1227.19"}}}',
          );
        default:
          response.statusCode = 404;
      }
      await response.close();
    });
  });

  tearDown(() => server.close(force: true));

  Future<int?> price(String currency) => splitsZecPrices(
    _noFeed(),
    http: NetworkHttpClient(
      torDesired: () => false,
      torBootstrapping: () => false,
    ),
    coinGecko: origin.replace(path: '/gecko'),
    binance: origin.replace(path: '/binance'),
    coinbase: origin.replace(path: '/coinbase'),
  ).minorUnitsPerZec(currency);

  test('USD comes from Binance when CoinGecko is blocked', () async {
    expect(await price('USD'), 139054);
    expect(asked, ['/gecko/simple/price', '/binance/api/v3/ticker/price']);
  });

  test('KES comes from Coinbase, and Binance is not asked', () async {
    expect(await price('KES'), 18015979);
    expect(asked, ['/gecko/simple/price', '/coinbase/v2/exchange-rates']);
  });

  test('a currency nobody prices is unpriced, not an error', () async {
    expect(await price('JPY'), isNull);
  });

  test('CoinGecko is asked without a key unless the build has one', () {
    expect(kVizorCoinGeckoApiKey, isEmpty);
    expect(coinGeckoHeaders().keys, [HttpHeaders.acceptHeader]);
  });
}
