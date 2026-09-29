/// The swap provider these screens settle non-ZEC debts through.
///
/// A recipient who asked to be paid in another asset cannot be an output of a
/// payment request (§8.5). The splits screens quote the swap, send the ZEC
/// leg and record it; what they need from this wallet is where to ask.
library;

import 'dart:convert';

import 'package:splitz_core/splitz_core.dart' show canonicalInstant;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

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

/// The body of a response, refused when its status says no: `swapAnswer`
/// reads the status before the bytes, so an error body is never read as a
/// quote.
Future<String> readSwapResponse(Future<NetworkHttpResponse> pending) async {
  final response = await pending;
  return swapAnswer(response.statusCode, response.bodyBytes);
}
