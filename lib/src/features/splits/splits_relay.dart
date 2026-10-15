/// Where this build syncs bills.
///
/// One construction, used by the screen and by the lanes that drive it: a
/// relay built twice is a relay that can be configured two ways.
library;

import 'dart:convert';

import 'package:splitz_host/splitz_host.dart';

import '../../core/network/network_http_client.dart';

/// The relay this build syncs bills through, or none.
///
/// The hosted relay unless a build names another: phones on different
/// networks reach each other's bills only through one, and it holds only
/// sealed blobs under channel digests (SPEC §15.5). A build given
/// `--dart-define=SPLITS_RELAY_URL=` (empty) has none, and bills move only by
/// scanned code.
const String splitsRelayUrl = String.fromEnvironment(
  'SPLITS_RELAY_URL',
  defaultValue: hostedSplitsRelay,
);

/// The relay this project hosts: tools/relay/cloudflare in the protocol tree.
const String hostedSplitsRelay = 'https://splitz-relay.splitz.workers.dev';

/// [http] is the wallet's own route — over Tor while the wallet's Tor is on,
/// direct while it is off — so bill sync never leaves the device any other
/// way than the wallet's own traffic does (SPEC §15.5).
SplitsRelay splitsRelay({
  NetworkHttpClient? http,
  String origin = splitsRelayUrl,
}) {
  if (origin.isEmpty) return const UnconfiguredSplitsRelay();
  final route = http ?? NetworkHttpClient();
  return HttpSplitsRelay(
    origin: Uri.parse(origin),
    post: (url, body) async {
      final response = await route.request(
        'POST',
        url,
        headers: const {'content-type': 'application/json'},
        bodyBytes: utf8.encode(body),
        timeout: const Duration(seconds: 20),
      );
      return utf8.decode(response.bodyBytes);
    },
    get: (url) async {
      final response = await route.request(
        'GET',
        url,
        timeout: const Duration(seconds: 20),
      );
      return utf8.decode(response.bodyBytes);
    },
  );
}
