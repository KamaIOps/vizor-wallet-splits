/// What one ZEC costs, for the splits screens.
///
/// This wallet already has a price feed. A second one here would be a second
/// answer on one screen, so this adapts the existing one rather than fetching
/// anything of its own.
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
    // feed's own precision is known — rather than at every place that reads
    // it. Rounded to nearest rather than truncated: truncating would make
    // every price a shade low, and the same shade every time.
    //
    // The product is checked, not just the price: a finite price can scale to
    // infinity, and `round()` throws on infinity rather than returning a
    // figure the bound below could refuse.
    final scaled = usd * _minorUnits;
    if (!scaled.isFinite) return null;
    final cents = scaled.round();

    // A figure that cannot be held exactly is not a price. An IEEE-754 double
    // is exact only to 2^53-1, and a bill's arithmetic is integers all the
    // way down.
    if (cents <= 0 || cents > 9007199254740991) return null;
    return cents;
  }
}

/// The wallet's own feed where it prices a currency, and the market for the
/// rest.
///
/// USD comes from [wallet], so the figure fixed onto a bill is the one every
/// other screen shows. Any other currency the ISO 4217 register gives an
/// exponent is read from [market]. A market that cannot be reached answers
/// empty here: the bill then asks for a price by hand, which is an ordinary
/// state (§15.6), rather than a screen raising over a figure it never needed.
class SplitsZecPrices implements ZecPrices {
  const SplitsZecPrices({required this.wallet, required this.market});

  final ZecPrices wallet;
  final ZecPrices market;

  @override
  Future<int?> minorUnitsPerZec(String currency) async {
    final own = await wallet.minorUnitsPerZec(currency);
    if (own != null) return own;
    try {
      return await market.minorUnitsPerZec(currency);
    } on Object {
      return null;
    }
  }
}

/// The prices the splits screens use: [SplitsZecPrices] over the wallet's
/// feed and the market, fetched through the wallet's own HTTP client so a
/// build routing through Tor sends these the same way.
///
/// The market is Binance for USD, then Coinbase for USD when Binance cannot
/// answer and for every other currency. Neither asks for a key.
///
/// The origins default to the build's; a test points them at a server of its
/// own.
ZecPrices splitsZecPrices(
  T Function<T>(ProviderListenable<T>) read, {
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
  return SplitsZecPrices(
    wallet: WalletZecPrices(read),
    market: FirstZecPrices([
      BinanceZecPrices(
        origin: binance ?? Uri.parse(kVizorBinanceMarketBaseUrl),
        get: get(json),
      ),
      CoinbaseZecPrices(
        origin: coinbase ?? Uri.parse(kVizorCoinbaseBaseUrl),
        get: get(json),
      ),
    ]),
  );
}
