/// Where a development run syncs bills, and nothing in a shipped build.
///
/// One construction, used by the screen and by the lanes that drive it: a
/// relay built twice is a relay that can be configured two ways.
library;

import 'dart:convert';

import 'package:splitz_host/splitz_host.dart';

import '../../core/network/network_http_client.dart';

/// The relay this build syncs bills through, or none.
///
/// Empty in every shipped build: a relay is named for a development run and
/// nowhere else, the same way the seed driver is.
const String splitsRelayUrl = String.fromEnvironment('SPLITS_RELAY_URL');

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

