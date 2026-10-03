/// What one ZEC costs, for the splits screens.
///
/// [splitsZecPrices] is what the screens use: Binance and Coinbase, held to
/// each other. [WalletZecPrices] adapts the wallet's home-screen feed, which
/// reads Binance alone; the mainnet swap lane prices from it.
library;

import 'dart:convert';

import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import '../../core/network/network_http_client.dart';
import '../../providers/zec_price_change_provider.dart';

/// The wallet's live ZEC price, as §7 wants it.
///
/// **USD only.** The feed prices ZEC against one currency, and answering for
/// any other would be inventing a number. Null is an ordinary answer: a bill
/// with no rate is an ordinary bill, and nothing invents a price to avoid
/// showing that state.
class WalletZecPrices implements ZecPrices {
  const WalletZecPrices(this._read);

  /// Reads the provider each time rather than holding a value: a price read
  /// once and kept would be stale exactly when somebody is about to fix it
  /// onto a bill.
  final T Function<T>(ProviderListenable<T>) _read;

  /// The only currency this feed prices.
  static const String currency = 'USD';

  /// The smallest unit of [currency], as a power of ten. USD has cents.
  static const int _minorUnits = 100;

  @override
  Future<int?> minorUnitsPerZec(String wanted) async {
    if (wanted.toUpperCase() != currency) return null;

    // Never a cached figure: this provider exposes only a price fetched
    // during its own lifetime, which is what a value about to be written
    // onto a bill needs.
    final usd = _read(zecLiveUsdUnitPriceProvider);
    if (usd == null || !usd.isFinite || usd <= 0) return null;

    // §7 snapshots an integer, so the rounding happens once — here, where the
    // feed's own precision is known — and the way the host's price readers
    // round: halves up, in integers. Multiplying the double instead rounds
    // the wrong way on figures like 1.005, whose binary value is a shade
    // under 1.005, so 1.005 * 100 is 100.49999999999999. The double's
    // shortest decimal text is the figure the feed sent, and that is what is
    // scaled. A figure written with an exponent is past any real price.
    final written = RegExp(r'^([0-9]+)\.([0-9]+)$').firstMatch(usd.toString());
    if (written == null) return null;
    final fraction = written[2]!.padRight(3, '0');
    final scaled =
        BigInt.parse(written[1]!) * BigInt.from(_minorUnits) +
        BigInt.parse(fraction.substring(0, 2)) +
        (fraction.codeUnitAt(2) >= 0x35 ? BigInt.one : BigInt.zero);
    // A figure that cannot be held exactly is not a price. An IEEE-754 double
    // is exact only to 2^53-1, and a bill's arithmetic is integers all the
    // way down.
    if (scaled <= BigInt.zero || scaled > BigInt.from(9007199254740991)) {
      return null;
    }
    return scaled.toInt();
  }
}

/// The prices the splits screens use, fetched through the wallet's own HTTP
/// client so a build routing through Tor sends these the same way.
///
/// Binance and Coinbase held to each other for USD ([AgreeingZecPrices] from the splitz host,
/// Coinbase's figure when they agree), and Coinbase for every other currency.
/// Neither asks for a key. The wallet's home-screen feed is not asked: it is
/// Binance's USDC figure read as USD, and a rate fixed onto a bill, or a
/// payment checked against, is one two markets agree on. When they disagree,
/// or neither answers, there is no price and the bill is priced by hand.
///
/// The origins default to the build's; a test points them at a server of its
/// own.
ZecPrices splitsZecPrices({
  required NetworkHttpClient http,
  Uri? binance,
  Uri? coinbase,
}) {
  JsonGet get(Map<String, String> headers) => (url) async {
    final response = await http.request('GET', url, headers: headers);
    if (response.statusCode != 200) {
      throw ZecPriceException('The price feed answered ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes);
  };
  const json = {'Accept': 'application/json'};
  return AgreeingZecPrices(
    BinanceZecPrices(
      origin: binance ?? Uri.parse(kVizorBinanceMarketBaseUrl),
      get: get(json),
    ),
    CoinbaseZecPrices(
      origin: coinbase ?? Uri.parse(kVizorCoinbaseBaseUrl),
      get: get(json),
    ),
  );
}
