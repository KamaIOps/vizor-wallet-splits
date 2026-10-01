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

SplitsRelay splitsRelay() {
  if (splitsRelayUrl.isEmpty) return const UnconfiguredSplitsRelay();
  final http = NetworkHttpClient();
  return HttpSplitsRelay(
    origin: Uri.parse(splitsRelayUrl),
    post: (url, body) async {
      final response = await http.request(
        'POST',
        url,
        headers: const {'content-type': 'application/json'},
        bodyBytes: utf8.encode(body),
        timeout: const Duration(seconds: 20),
      );
      return utf8.decode(response.bodyBytes);
    },
    get: (url) async {
      final response = await http.request(
        'GET',
        url,
        timeout: const Duration(seconds: 20),
      );
      return utf8.decode(response.bodyBytes);
    },
  );
}
