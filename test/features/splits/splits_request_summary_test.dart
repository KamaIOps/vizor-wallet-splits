/// Reading a ZIP 321 request back for the payer's review screen.
///
/// The URIs here are the protocol's own output, taken from `renderUri` in
/// `splitz_core`, not written by hand: the parameter layout is the thing under
/// test, so inventing it would test this file against itself.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/zcash/zip321_payment_request.dart';
import 'package:zcash_wallet/src/features/splits/splits_request_summary.dart';

void main() {
  // zcash:u1addr0?amount=0.0003
  const one = 'zcash:u1addr0?amount=0.0003';

  // The shape a bill settled between several people actually produces: every
  // address in the query, including the first.
  const two =
      'zcash:?address=u1addr0&amount=0.0003'
      '&address.1=u1addr1&amount.1=0.00030001';

  const four =
      'zcash:?address=u1addr0&amount=0.0003'
      '&address.1=u1addr1&amount.1=0.00030001'
      '&address.2=u1addr2&amount.2=0.00030002'
      '&address.3=u1addr3&amount.3=0.00030003';

  group('recipient count', () {
    test('one payment keeps its address in the path and counts as one', () {
      expect(splitsRecipientCount(one), 1);
    });

    test('two payments are two, not three', () {
      // Counting the parameters and adding one is right for the single shape
      // and wrong here, where it tells the payer they are paying three people.
      expect(splitsRecipientCount(two), 2);
    });

    test('four payments are four', () {
      expect(splitsRecipientCount(four), 4);
    });
  });

  group('total', () {
    test('a single amount is scaled by 10^8', () {
      expect(splitsTotalZatoshi(one), BigInt.from(30000));
    });

    test('every amount is summed', () {
      expect(splitsTotalZatoshi(two), BigInt.from(30000 + 30001));
      expect(
        splitsTotalZatoshi(four),
        BigInt.from(30000 + 30001 + 30002 + 30003),
      );
    });

    test('a whole number of ZEC carries no fraction', () {
      expect(splitsTotalZatoshi('zcash:u1a?amount=1'), BigInt.from(100000000));
    });

    test('a figure a double cannot hold exactly is still exact', () {
      // 21,000,000 ZEC is 2.1e15 zatoshi, past the 2^53-1 a double is exact
      // to, so reading this through a double loses zatoshi.
      expect(
        splitsTotalZatoshi('zcash:u1a?amount=21000000.00000001'),
        BigInt.parse('2100000000000001'),
      );
    });
  });

  // The wallet parses ZIP 321 properly elsewhere, for the send flow. These
  // helpers read the same URIs with a regex because they run on a display
  // path that must not throw. Two readings of one string are worth nothing if
  // they are never compared, so they are compared here.
  group('agrees with the wallet\'s own parser', () {
    for (final (name, uri, expected) in [
      ('one', one, 1),
      ('two', two, 2),
      ('four', four, 4),
    ]) {
      test('$name: both readings count $expected', () {
        expect(splitsRecipientCount(uri), expected);
        expect(Zip321PaymentRequest.parse(uri).payments.length, expected);
      });
    }
  });
}
