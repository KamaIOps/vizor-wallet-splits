/// What one ZEC costs, for the splits screens.
///
/// This wallet already has a price feed. A second one here would be a second
/// answer on one screen, so this adapts the existing one rather than fetching
/// anything of its own.
library;

import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:vizor_splitz/vizor_splitz.dart';

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
    final cents = (usd * _minorUnits).round();

    // A figure that cannot be held exactly is not a price. An IEEE-754 double
    // is exact only to 2^53-1, and a bill's arithmetic is integers all the
    // way down.
    if (cents <= 0 || cents > 9007199254740991) return null;
    return cents;
  }
}
