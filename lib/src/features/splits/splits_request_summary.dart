/// What a ZIP 321 payment request asks for, read back for display.
///
/// **Display only.** The transaction is built by Rust from the URI itself, so
/// a wrong figure here shows a wrong number beside a right transaction rather
/// than sending the wrong money. That makes it a lie told to the payer at the
/// moment they confirm, which is its own kind of serious.
library;

/// How many recipients [paymentRequestUri] names.
///
/// ZIP 321 has two shapes and they count differently. One payment puts its
/// address in the path — `zcash:<addr>?amount=…` — and emits no `address`
/// parameter at all. Several payments put every address in the query,
/// including the first: `zcash:?address=…&amount=…&address.1=…&amount.1=…`.
///
/// So no parameter means one recipient, and otherwise the parameters are the
/// recipients. Adding one to the count is right for the first shape and wrong
/// for the second, where it reports three people paid for two.
int splitsRecipientCount(String paymentRequestUri) {
  final named = RegExp(
    r'[?&]address(\.\d+)?=',
  ).allMatches(paymentRequestUri).length;
  return named == 0 ? 1 : named;
}

/// What [paymentRequestUri] asks for in total, in zatoshi.
///
/// Amounts in ZIP 321 are decimal ZEC. They are read as integers scaled by
/// 10^8 rather than through a double, because a double cannot hold every
/// zatoshi of a large figure exactly.
BigInt splitsTotalZatoshi(String paymentRequestUri) {
  var total = BigInt.zero;
  for (final match in RegExp(
    r'[?&]amount(?:\.\d+)?=([0-9.]+)',
  ).allMatches(paymentRequestUri)) {
    final parts = match.group(1)!.split('.');
    final whole = BigInt.tryParse(parts[0].isEmpty ? '0' : parts[0]);
    final fraction = parts.length > 1
        ? BigInt.tryParse(parts[1].padRight(8, '0').substring(0, 8))
        : BigInt.zero;
    if (whole == null || fraction == null) continue;
    total += whole * BigInt.from(100000000) + fraction;
  }
  return total;
}
