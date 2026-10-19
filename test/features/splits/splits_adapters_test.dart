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

/// A Tor route that answers as the relay does and records what it carried.
class _TorRoute implements TorHttpBridge {
  final calls = <String>[];

  @override
  Future<NetworkHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) {
    calls.add('GET ${uri.path}');
    return _answer(200, '{"blobs":[]}');
  }

  @override
  Future<NetworkHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) {
    final push = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
    final blobs = (push['blobs'] as List).cast<String>();
    final stamped = relayWorkHolds(
      uri.pathSegments.last,
      blobs,
      push['work'] as String,
      relayWorkBase,
    );
    calls.add('POST ${uri.path} stamped=$stamped');
    return _answer(200, '{"ok":true}');
  }

  @override
  Future<NetworkHttpResponse> download(
    Uri uri, {
    required Map<String, String> headers,
    required String destinationPath,
  }) => throw UnimplementedError();
}

void main() {
  group('relay traffic takes the wallet\'s route (SPEC §15.5)', () {
    final channel = 'c' * 64;

    test('with Tor on, a push and a fetch go over Tor, stamped', () async {
      final tor = _TorRoute();
      final relay = splitsRelay(
        origin: 'https://relay.test',
        http: NetworkHttpClient(
          torDesired: () => true,
          torBootstrapping: () => false,
          torBridge: tor,
        ),
      );
      await relay.push(channel, ['x']);
      expect(await relay.fetch(channel), isEmpty);
      expect(tor.calls, ['POST /c/$channel stamped=true', 'GET /c/$channel']);
    });

    test('with Tor off, nothing is handed to Tor', () async {
      final tor = _TorRoute();
      final relay = splitsRelay(
        // Nothing listens here; the direct route is what is being told apart.
        origin: 'http://127.0.0.1:9',
        http: NetworkHttpClient(
          torDesired: () => false,
          torBootstrapping: () => false,
          torBridge: tor,
        ),
      );
      await expectLater(
        relay.fetch(channel),
        throwsA(isA<SplitsRelayException>()),
      );
      expect(tor.calls, isEmpty);
    });

    test('with Tor starting, the request waits on Tor, not direct', () async {
      // The bridge holds a request until Tor is up; nothing listens at this
      // origin, so an answer at all means the direct route was not taken.
      final tor = _TorRoute();
      final relay = splitsRelay(
        origin: 'http://127.0.0.1:9',
        http: NetworkHttpClient(
          torDesired: () => true,
          torBootstrapping: () => true,
          torBridge: tor,
        ),
      );
      expect(await relay.fetch(channel), isEmpty);
      expect(tor.calls, ['GET /c/$channel']);
    });
  });

  group('the relay a build gets', () {
    test('no SPLITS_RELAY_URL means no relay', () {
      // A build compiled without the define syncs nowhere: bills move by
      // scanned code until a relay is named.
      expect(splitsRelayUrl, isEmpty);
      expect(splitsRelay(), isA<UnconfiguredSplitsRelay>());
    });

    test('a named origin is the relay a build gets', () {
      expect(
        splitsRelay(origin: 'https://relay.example'),
        isA<HttpSplitsRelay>(),
      );
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
