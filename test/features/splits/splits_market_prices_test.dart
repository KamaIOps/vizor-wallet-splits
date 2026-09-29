/// The market behind the splits screens' prices, over real HTTP: Binance's
/// ZECUSDC for USD, and Coinbase for USD when Binance cannot answer and for
/// every other currency.
library;

import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/splits/splits_prices.dart';

/// A wallet feed with no price, so every figure comes from the market.
T Function<T>(ProviderListenable<T>) _noFeed() =>
    <T>(ProviderListenable<T> _) => null as T;

void main() {
  late HttpServer server;
  late Uri origin;
  final asked = <String>[];
  var binanceDown = false;

  setUp(() async {
    asked.clear();
    binanceDown = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      asked.add(request.uri.path);
      final response = request.response;
      switch (request.uri.path) {
        case '/binance/api/v3/ticker/price' when binanceDown:
          response.statusCode = 451;
        case '/binance/api/v3/ticker/price':
          response.write('{"symbol":"ZECUSDC","price":"1391.88000000"}');
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
    binance: origin.replace(path: '/binance'),
    coinbase: origin.replace(path: '/coinbase'),
  ).minorUnitsPerZec(currency);

  test('USD comes from Binance, and Coinbase is not asked', () async {
    expect(await price('USD'), 139188);
    expect(asked, ['/binance/api/v3/ticker/price']);
  });

  test('USD comes from Coinbase when Binance cannot answer', () async {
    binanceDown = true;
    expect(await price('USD'), 138905);
    expect(asked, [
      '/binance/api/v3/ticker/price',
      '/coinbase/v2/exchange-rates',
    ]);
  });

  test('KES comes from Coinbase, and Binance is not asked', () async {
    expect(await price('KES'), 18015979);
    expect(asked, ['/coinbase/v2/exchange-rates']);
  });

  test('a currency nobody prices is unpriced, not an error', () async {
    expect(await price('JPY'), isNull);
  });
}
