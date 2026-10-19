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
/// None unless a build names one with `--dart-define=SPLITS_RELAY_URL=<origin>`.
/// Without a relay, bills move only by scanned code. Phones on different
/// networks reach each other's bills only through one, and it holds only
/// sealed blobs under channel digests (SPEC §15.5).
///
/// No default: this build writes sealed frames v2 and works for each push, and
/// a relay that serves v1 readers must not receive them.
const String splitsRelayUrl = String.fromEnvironment('SPLITS_RELAY_URL');

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
