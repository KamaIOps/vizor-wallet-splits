/// Turning the wallet's ZEC price into the integer §7 snapshots onto a bill.
library;

import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/splits_prices.dart';

/// A reader that answers every provider with [value].
///
/// `WalletZecPrices` reads exactly one provider, so answering all of them
/// alike is enough and keeps the fake to one line.
T Function<T>(ProviderListenable<T>) _reader(double? value) =>
    <T>(ProviderListenable<T> _) => value as T;

Future<int?> _cents(double? usd) =>
    WalletZecPrices(_reader(usd)).minorUnitsPerZec('USD');

void main() {
  group('currency', () {
    test('USD is priced', () async {
      expect(await _cents(42.0), 4200);
    });

    test('any other currency is null rather than an invented number', () async {
      final prices = WalletZecPrices(_reader(42.0));
      expect(await prices.minorUnitsPerZec('EUR'), isNull);
      expect(await prices.minorUnitsPerZec('GBP'), isNull);
    });

    test('the currency is matched without regard to case', () async {
      expect(
        await WalletZecPrices(_reader(42.0)).minorUnitsPerZec('usd'),
        4200,
      );
    });
  });

  group('rounding', () {
    test(
      'halves up, from the figure the feed sent, never from its binary',
      () async {
        // 1.005 * 100 is 100.49999999999999 in binary floating point, and
        // 0.285 * 100 is 28.499999999999996: multiplying rounds both down.
        expect(await _cents(1.005), 101);
        expect(await _cents(0.285), 29);
        expect(await _cents(36.865), 3687);
        expect(await _cents(1.0049), 100);
        // Written with an exponent, a figure is past any real price.
        expect(await _cents(1e-7), isNull);
      },
    );

    test('to nearest, not toward zero', () async {
      // Truncating would make every price a shade low, and the same shade
      // every time, which is a bias rather than a rounding error. 0.125 and
      // 0.135 are chosen because they scale to an exact .5, so the two
      // behaviours actually differ: 12.5 rounds to 13 and truncates to 12.
      expect(await _cents(0.125), 13);
      expect(await _cents(0.135), 14);
    });
  });

  group('a figure that is not a price is refused, never thrown', () {
    test('no price yet', () async => expect(await _cents(null), isNull));
    test('zero', () async => expect(await _cents(0), isNull));
    test('negative', () async => expect(await _cents(-1.0), isNull));
    test('infinite', () async => expect(await _cents(double.infinity), isNull));
    test('NaN', () async => expect(await _cents(double.nan), isNull));

    test('a price too large to hold exactly', () async {
      // 1e306 * 100 is finite but saturates past 2^53-1 when rounded.
      expect(await _cents(1e306), isNull);
    });

    test('a price whose cents overflow to infinity', () async {
      // The price itself is finite, so a check on the price alone lets it
      // through; the product is not, and rounding infinity throws rather
      // than returning a number a guard could catch.
      expect(await _cents(1e307), isNull);
    });
  });
}
