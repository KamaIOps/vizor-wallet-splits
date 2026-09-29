/// The pieces the splits feature takes from the packages, as this wallet
/// wires them: its prices, its keychain against §15, and the transaction ids
/// it hands the package to match.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_host/splitz_host.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/features/splits/splits_prices.dart';
import 'package:zcash_wallet/src/features/splits/splits_received.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';
import 'package:zcash_wallet/src/rust/frb_generated.dart';

/// A market that cannot be reached.
class _Unreachable implements ZecPrices {
  @override
  Future<int?> minorUnitsPerZec(String currency) async =>
      throw const ZecPriceException('The price feed answered 429');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a transaction id from the history, as a send reports it', () {
    test('the bytes are reversed and lower-cased', () {
      final stored = [
        for (var i = 0; i < 32; i++) i,
      ].map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final shown = txidForDisplay(stored.toUpperCase());
      expect(shown.substring(0, 4), '1f1e');
      expect(shown.substring(60), '0100');
      expect(txidForDisplay(shown), stored, reason: 'reversing twice is none');
    });
  });

  group('prices', () {
    test('the wallet feed first, the market for the rest', () async {
      const prices = SplitsZecPrices(
        wallet: FixedZecPrices({'USD': 138819}),
        market: FixedZecPrices({'USD': 1, 'EUR': 122241}),
      );
      expect(await prices.minorUnitsPerZec('USD'), 138819);
      expect(await prices.minorUnitsPerZec('EUR'), 122241);
      expect(await prices.minorUnitsPerZec('GBP'), isNull);
    });

    test('a market that cannot be reached leaves the bill to be priced by '
        'hand', () async {
      final prices = SplitsZecPrices(
        wallet: const NoZecPrices(),
        market: _Unreachable(),
      );
      expect(await prices.minorUnitsPerZec('EUR'), isNull);
    });

    test('keeps §15.6', () async {
      const prices = SplitsZecPrices(
        wallet: FixedZecPrices({'USD': 138819}),
        market: FixedZecPrices({'EUR': 122241}),
      );
      expect(await checkZecPrices(prices), isEmpty);
      expect(await checkZecPrices(prices, priced: 'EUR'), isEmpty);
    });
  });

  group('the keychain', () {
    setUpAll(() => RustLib.initMock(api: _RustSecretApiFake()));
    tearDownAll(RustLib.dispose);

    test('keeps §15.3 in an unlocked session', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final secure = AppSecureStore.testing(
        storage: const FlutterSecureStorage(),
      )..setSessionPassword('a session password');
      final store = KeychainSecretStore(store: secure);
      expect(await checkSecretStore(store, runId: 'wallet'), isEmpty);
    });
  });
}

/// The wallet's Rust secret API, as `test/core/storage/app_secure_store_test.dart`
/// fakes it.
class _RustSecretApiFake implements RustLibApi {
  @override
  Future<Uint8List> crateApiSecretDecryptSecretPayload({
    required String payloadJson,
    required String password,
    required String saltBase64,
  }) async {
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
    final cipherText = payload['c'] as String;
    final mac = payload['m'] as String;
    if (mac != _fakeMac(password, saltBase64, cipherText)) {
      throw StateError('Failed to decrypt secure-storage payload');
    }
    return Uint8List.fromList(base64Decode(cipherText));
  }

  @override
  Future<String> crateApiSecretDeriveSecretPasswordVerifier({
    required String password,
    required String saltBase64,
  }) async {
    return base64Encode(utf8.encode('$saltBase64:$password'));
  }

  @override
  Future<String> crateApiSecretEncryptSecretPayload({
    required List<int> plainBytes,
    required String password,
    required String saltBase64,
  }) async {
    final cipherText = base64Encode(plainBytes);
    return jsonEncode({
      'v': 1,
      'n': base64Encode(utf8.encode('test-nonce')),
      'c': cipherText,
      'm': _fakeMac(password, saltBase64, cipherText),
    });
  }

  String _fakeMac(String password, String saltBase64, String cipherText) {
    return base64Encode(utf8.encode('$password:$saltBase64:$cipherText'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
