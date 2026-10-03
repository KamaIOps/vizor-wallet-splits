/// What a ZIP 321 payment request asks for, read back for display.
///
/// **Display only.** The transaction is built by Rust from the URI itself, so
/// a wrong figure here shows a wrong number beside a right transaction rather
/// than sending the wrong money. That makes it a lie told to the payer at the
/// moment they confirm, which is its own kind of serious.
library;

import 'package:splitz_core/splitz_core.dart' as protocol;

/// How many recipients [paymentRequestUri] names, read by the protocol's own
/// ZIP 321 reader; none for a request it refuses. A display path, so it
/// answers rather than throws.
int splitsRecipientCount(String paymentRequestUri) {
  try {
    return protocol.readRequest(paymentRequestUri).length;
  } on Object {
    return 0;
  }
}

/// What [paymentRequestUri] asks for in total, in zatoshi, read by the
/// protocol's own ZIP 321 reader; zero for a request it refuses.
BigInt splitsTotalZatoshi(String paymentRequestUri) {
  try {
    return protocol
        .readRequest(paymentRequestUri)
        .fold(BigInt.zero, (sum, p) => sum + BigInt.from(p.zatoshi));
  } on Object {
    return BigInt.zero;
  }
}
