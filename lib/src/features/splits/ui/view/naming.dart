/// How this wallet reads a bill: naming, and who opened it.
///
/// None of this is a rule two wallets must agree on — every permission on a
/// bill is decided by participant id, and nothing here feeds into that — so it
/// stays out of the protocol and lives with the app that renders it.
library;

import 'package:splitz_core/splitz_core.dart' as protocol;

import 'package:splitz_host/splitz_host.dart'
    show currencyExponent, formatBaseUnits;

/// What [SplitsController.sentOn] reports for a bill in [currency], as a
/// line; null when nothing is on its way.
String? sentNotConfirmed(int? sent, String currency) => sent == null
    ? 'Payments sent, not yet confirmed'
    : sent > 0
    ? '${formatAmount(sent, currency)} sent, not yet confirmed'
    : null;

/// That where [who] is paid changed.
///
/// Said to be their doing only when [bound]: §10.7 binds a participant's
/// record to their key once they join with one, and until then anybody
/// holding the invite can write it.
String payoutChangedLine(String who, {required bool bound}) =>
    bound ? '$who changed where they are paid' : 'Where $who is paid changed';

/// Renders [minorUnits] of [currency] as a figure a person reads.
///
/// Integer arithmetic throughout. The protocol's amounts are minor units and
/// no floating point touches one: a double cannot hold every cent of a large
/// bill exactly, and the rounding it would introduce is money.
/// With [withCurrency] false the code is left off, which is what an input
/// field wants: the figure goes back through `parseAmountIn`, and that
/// reads digits rather than a rendered label.
///
/// [exponent] defaults to [currency]'s ISO 4217 exponent. A code the register
/// gives none (§2.1) is shown as the count of minor units it is, never scaled
/// by a guess.
String formatAmount(
  int minorUnits,
  String currency, {
  int? exponent,
  bool withCurrency = true,
}) {
  final negative = minorUnits < 0;
  // Negated as a BigInt: the smallest 64-bit value has no positive twin.
  final magnitude = BigInt.from(minorUnits).abs();
  final suffix = withCurrency ? ' $currency' : '';
  final scaleBy = exponent ?? currencyExponent(currency);
  if (scaleBy == null) {
    return '${negative ? '-' : ''}$magnitude minor units$suffix';
  }
  if (scaleBy == 0) return '${negative ? '-' : ''}$magnitude$suffix';
  final exponentUsed = scaleBy;
  final scale = BigInt.from(10).pow(exponentUsed);
  final whole = magnitude ~/ scale;
  final fraction = (magnitude % scale).toString().padLeft(exponentUsed, '0');
  return '${negative ? '-' : ''}$whole.$fraction$suffix';
}

/// The sign every reader of [currency] knows it by, or null for one shown
/// by its ISO 4217 code.
String? currencySymbol(String currency) => switch (currency) {
  'USD' => r'$',
  'EUR' => '€',
  'GBP' => '£',
  'INR' => '₹',
  'JPY' => '¥',
  _ => null,
};

/// [minorUnits] with its currency's sign in front — `$3000.00`, `-$5.00` —
/// or, for a currency with none, as [formatAmount] writes it.
String formatWithSymbol(int minorUnits, String currency) {
  final symbol = currencySymbol(currency);
  if (symbol == null) return formatAmount(minorUnits, currency);
  final figure = formatAmount(minorUnits, currency, withCurrency: false);
  return figure.startsWith('-')
      ? '-$symbol${figure.substring(1)}'
      : '$symbol$figure';
}

/// [zatoshi] as ZEC with every digit (§8.2), for a figure a record states.
///
/// A count no transaction carries — none, fewer, or more than will ever
/// exist — is said as such rather than refused: a peer writes these figures,
/// and a screen that throws on one cannot offer to withdraw the record.
String formatZec(int zatoshi) => zatoshi == 0
    ? '0 ZEC'
    : zatoshi < 0
    ? 'a negative amount of ZEC'
    : zatoshi > protocol.maxZatoshi
    ? 'more ZEC than exists'
    : '${protocol.renderAmount(zatoshi)} ZEC';

/// The wallet's reason a send could not be built, with any zatoshi count it
/// names said as ZEC. The wallet states its balance shortfall as
/// "Insufficient balance (have H, need N including fee)", both in zatoshi.
String describeSendFailure(String detail) {
  final short = RegExp(
    r'insufficient balance \(have (\d+), need (\d+) including fee\)',
    caseSensitive: false,
  ).firstMatch(detail);
  final have = int.tryParse(short?.group(1) ?? '');
  final need = int.tryParse(short?.group(2) ?? '');
  if (have == null || need == null) return detail;
  return 'Not enough ZEC: this payment needs ${formatZec(need)} including '
      'the fee, and the wallet has ${formatZec(have)}.';
}

/// [base] units of a token with [decimals] places, as whole tokens — the
/// host's [formatBaseUnits] — or, for a figure that is not a plain run of
/// digits, as it came, labelled as base units.
String tokenAmount(String base, int decimals) =>
    formatBaseUnits(base, decimals) ?? '$base base units';

/// `2nd`, `3rd`, `11th`: a position in somebody's list of preferences.
String ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen
      ? 'th'
      : switch (n % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$n$suffix';
}
