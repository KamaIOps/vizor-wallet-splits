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

/// Two sources asked for one currency, held to each other.
///
/// Binance prices ZEC in USDC and its figure is read as USD, so a stablecoin
/// that slips off its peg moves the price with nothing on screen to say so.
/// Coinbase quotes USD itself. When both answer and differ by more than
/// [toleranceBp] basis points of the lower, there is no price: a rate a bill
/// is fixed at, or a payment is checked against, is not one two markets
/// disagree on. When one answers, its figure stands, so one market being down
/// does not stop a bill being priced.
class AgreeingZecPrices implements ZecPrices {
  const AgreeingZecPrices(this.first, this.second, {this.toleranceBp = 200});

  final ZecPrices first;
  final ZecPrices second;
  final int toleranceBp;

  @override
  Future<int?> minorUnitsPerZec(String currency) async {
    Future<int?> ask(ZecPrices source) async {
      try {
        return await source.minorUnitsPerZec(currency);
      } on Object {
        return null;
      }
    }

    final a = await ask(first);
    final b = await ask(second);
    if (a == null || b == null) return a ?? b;
    final low = a < b ? a : b;
    final high = a < b ? b : a;
    // In integers: (high - low) * 10000 <= low * toleranceBp. Both figures
    // are at most 2^53 - 1 cents, well inside 64 bits once scaled.
    final apart = BigInt.from(high - low) * BigInt.from(10000);
    if (apart > BigInt.from(low) * BigInt.from(toleranceBp)) return null;
    return b;
  }
}

/// The prices the splits screens use, fetched through the wallet's own HTTP
/// client so a build routing through Tor sends these the same way.
///
/// Binance and Coinbase held to each other for USD ([AgreeingZecPrices],
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
