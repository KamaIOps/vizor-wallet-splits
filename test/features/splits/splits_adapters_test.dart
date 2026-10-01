/// The two seams the splits screens reach the network through.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_host/splitz_host.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/splits/splits_relay.dart';
import 'package:zcash_wallet/src/features/splits/splits_swaps.dart';

Future<NetworkHttpResponse> _answer(int status, String body) async =>
    NetworkHttpResponse(
      statusCode: status,
      bodyBytes: Uint8List.fromList(utf8.encode(body)),
    );

void main() {
  group('the relay a build gets', () {
    test('no SPLITS_RELAY_URL means the hosted relay', () {
      // A build compiled without the define syncs through the hosted relay,
      // over https, at the origin the protocol tree deploys.
      expect(splitsRelayUrl, hostedSplitsRelay);
      expect(Uri.parse(hostedSplitsRelay).scheme, 'https');
      expect(splitsRelay(), isA<HttpSplitsRelay>());
    });
  });

  group('reading the swap provider', () {
    test('a 200 gives its body back', () async {
      expect(
        await readSwapResponse(_answer(200, '{"quote":1}')),
        '{"quote":1}',
      );
    });

    test('a 400 is refused on the merits, not retried', () async {
      // The body of a refusal parses as JSON too. Handing it on would read an
      // error object as a price.
      await expectLater(
        readSwapResponse(_answer(400, '{"error":"no route"}')),
        throwsA(
          isA<SwapException>().having(
            (e) => e.isTransient,
            'isTransient',
            isFalse,
          ),
        ),
      );
    });

    test('a refusal carries the reason the provider gave', () async {
      await expectLater(
        readSwapResponse(
          _answer(
            400,
            '{"message":"slippageTolerance should not be empty",'
            '"statusCode":400}',
          ),
        ),
        throwsA(
          isA<SwapException>().having(
            (e) => e.message,
            'message',
            'The swap provider answered 400: slippageTolerance should not be empty',
          ),
        ),
      );
      // No message, or a body that is not JSON, leaves the status alone.
      await expectLater(
        readSwapResponse(_answer(400, 'no')),
        throwsA(
          isA<SwapException>().having(
            (e) => e.message,
            'message',
            'The swap provider answered 400',
          ),
        ),
      );
    });

    test('a 500 is transient, so a retry is allowed', () async {
      await expectLater(
        readSwapResponse(_answer(503, 'upstream down')),
        throwsA(
          isA<SwapException>().having(
            (e) => e.isTransient,
            'isTransient',
            isTrue,
          ),
        ),
      );
    });

    test('399 and 400 are the boundary', () async {
      expect(await readSwapResponse(_answer(399, 'ok')), 'ok');
      await expectLater(
        readSwapResponse(_answer(400, 'no')),
        throwsA(isA<SwapException>()),
      );
    });

    test(
      'a body that is not valid UTF-8 does not throw a decoder error',
      () async {
        // The status decides; malformed bytes are replaced rather than raised,
        // so a provider sending rubbish is a refusal and not a crash.
        final bad = Future.value(
          NetworkHttpResponse(
            statusCode: 200,
            bodyBytes: Uint8List.fromList([0xff, 0xfe, 0x41]),
          ),
        );
        expect(await readSwapResponse(bad), contains('A'));
      },
    );
  });
}
