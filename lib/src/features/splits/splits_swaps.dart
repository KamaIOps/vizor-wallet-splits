/// The swap provider these screens settle non-ZEC debts through.
///
/// A recipient who asked to be paid in another asset cannot be an output of a
/// payment request (§8.5). The splits screens quote the swap, send the ZEC
/// leg and record it; what they need from this wallet is where to ask.
library;

import 'dart:convert';

import 'package:splitz_core/splitz_core.dart' show canonicalInstant;
import 'package:splitz_flutter/splitz_flutter.dart';

import '../../core/network/network_http_client.dart';

/// Where quotes are asked for.
///
/// This wallet's own endpoint rather than the provider's, so no credential
/// ships in the app: whatever the provider requires is held behind this and
/// never reaches a device.
const String splitsSwapOrigin =
    'https://functions.vizor.cash/api/near-intents/1click';

/// How the provider names ZEC on the Zcash chain itself.
///
/// Read from the provider's own token list rather than assumed. The same
/// symbol is listed against five chains — `near`, `sol`, `starknet`, `aptos`
/// and `zec` — and only the last is the one a payer sends from their own
/// wallet. Quoting one of the others would price a deposit on a chain this
/// wallet cannot send on.
const String splitsZecAssetId = 'nep141:zec.omft.near';

/// Identifies this wallet to the provider.
const String splitsSwapReferral = 'vizor';

/// How long this wallet asks a quote to stand for.
const Duration splitsQuoteValidity = Duration(minutes: 10);

/// The provider the splits screens use.
///
/// Built over the wallet's own HTTP client, so a swap goes out the same way
/// every other request does — one proxy configuration, one set of timeouts.
SwapProvider splitsSwaps({required NetworkHttpClient http}) => OneClickSwaps(
  origin: Uri.parse(splitsSwapOrigin),
  zecAssetId: splitsZecAssetId,
  referral: splitsSwapReferral,
  // The clock and the calendar are the wallet's (§15.1); the package
  // carries neither.
  deadline: () => canonicalInstant(
    DateTime.now().toUtc().add(splitsQuoteValidity).toIso8601String(),
  ),
  post: (url, body) => readSwapResponse(
    http.request(
      'POST',
      url,
      headers: const {'Content-Type': 'application/json'},
      bodyBytes: utf8.encode(body),
    ),
  ),
  get: (url) => readSwapResponse(http.request('GET', url)),
);

/// The body of a response, refusing a status the provider uses to say no.
///
/// A 4xx or 5xx carries a body too, and decoding it as a quote would read an
/// error object as a price. The status is checked before the bytes are; the
/// provider's own `message`, when it sends one, goes into the refusal, since
/// it names what to change ("slippageTolerance should not be empty").
Future<String> readSwapResponse(Future<NetworkHttpResponse> pending) async {
  final response = await pending;
  final body = utf8.decode(response.bodyBytes, allowMalformed: true);
  if (response.statusCode >= 400) {
    final said = _providerMessage(body);
    throw SwapException(
      'The swap provider answered ${response.statusCode}'
      '${said == null ? '' : ': $said'}',
      // 5xx may work on a retry; a 4xx is a refusal on the merits.
      isTransient: response.statusCode >= 500,
    );
  }
  return body;
}

/// The `message` of an error body, or null when there is none to read.
///
/// A string, or a list of strings joined; cut at 200 characters so a verbose
/// provider cannot fill the screen.
String? _providerMessage(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final raw = decoded['message'];
  final text = switch (raw) {
    String s => s,
    List l => l.whereType<String>().join('; '),
    _ => '',
  }.trim();
  if (text.isEmpty) return null;
  return text.length <= 200 ? text : '${text.substring(0, 200)}…';
}
