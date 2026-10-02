/// The pieces the splits feature takes from the packages, as this wallet
/// wires them: its keychain against §15, and the transaction ids
/// it hands the package to match.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_host/splitz_host.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/features/splits/splits_received.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';
import 'package:zcash_wallet/src/rust/frb_generated.dart';

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

  group('the keychain', () {
    setUpAll(() => RustLib.initMock(api: _RustSecretApiFake()));
    tearDownAll(RustLib.dispose);

    test('keeps §15.3 in an unlocked session', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final secure = AppSecureStore.testing(
        storage: const FlutterSecureStorage(),
      )..setSessionPassword('a session password');
      final store = KeychainSecretStore(
        accountUuid: 'account-1',
        store: secure,
      );
      expect(await checkSecretStore(store, runId: 'wallet'), isEmpty);
    });

    group('names written before accounts were kept apart', () {
      late AppSecureStore secure;
      const billKey = 'splitz_bill_key_LvRN_fusXc5LJBeEjZNCBQ';
      const seedA = 'splitz_identity_seed_v2_account-a';
      const seedC = 'splitz_identity_seed_v2_account-c';

      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        secure = AppSecureStore.testing(storage: const FlutterSecureStorage())
          ..setSessionPassword('a session password');
        await secure.writeSecretString(billKey, 'K');
        await secure.writeSecretString(seedA, 'seed-a');
        await secure.writeSecretString(seedC, 'seed-c');
      });

      KeychainSecretStore of(String account) =>
          KeychainSecretStore(accountUuid: account, store: secure);

      test('a shared bill key is read by every account', () async {
        expect(await of('account-a').read(billKey), 'K');
        expect(await of('account-b').read(billKey), 'K');
        expect(await secure.readSecretStringWithOptions(billKey), 'K');
      });

      test('a forgotten bill key is gone for every account', () async {
        expect(await of('account-a').read(billKey), 'K');
        await of('account-a').delete(billKey);
        expect(await of('account-a').read(billKey), isNull);
        expect(await of('account-b').read(billKey), isNull);
      });

      test('an identity seed moves to its own account only', () async {
        expect(await of('account-a').read(seedA), 'seed-a');
        expect(await secure.readSecretStringWithOptions(seedA), isNull);
        expect(await secure.readSecretStringWithOptions(seedC), 'seed-c');
      });

      test('removing an account removes its old-name identity', () async {
        await secure.deleteSplitsSecretsFor('account-c');
        expect(await secure.readSecretStringWithOptions(seedC), isNull);
        expect(await secure.readSecretStringWithOptions(seedA), 'seed-a');
        expect(await secure.readSecretStringWithOptions(billKey), 'K');
      });
    });

    group('a passcode change', () {
      const p0 = 'Firstpass1!';
      const p1 = 'Secondpass1!';
      const p2 = 'Thirdpass1!';
      const raw = FlutterSecureStorage();
      late AppSecureStore secure;

      /// A keychain holding [stale] sealed under [p0] while the passcode is
      /// [p1]: what a rotation that skipped it leaves behind.
      Future<void> leaveUnderP0(String stale) async {
        FlutterSecureStorage.setMockInitialValues({});
        secure = AppSecureStore.testing(storage: raw);
        await secure.configurePassword(p0);
        await secure.writeAccountMnemonic('acct', 'abandon abandon abandon');
        await secure.writeSecretString(stale, 'OLD');
        final sealedUnderP0 = await raw.read(key: stale);
        expect(
          await secure.changePassword(currentPassword: p0, newPassword: p1),
          isTrue,
        );
        await raw.write(key: stale, value: sealedUnderP0);
        await secure.writeSecretString(
          'splitz_bill_key_fresh@account-a',
          'FRESH',
        );
      }

      test('goes through past a splits secret under an older one', () async {
        await leaveUnderP0('splitz_bill_key_b1');
        final before = await raw.read(key: 'splitz_bill_key_b1');
        expect(
          await secure.changePassword(currentPassword: p1, newPassword: p2),
          isTrue,
        );
        secure.clearSessionPassword();
        expect(await secure.verifyPassword(p2), isTrue);
        expect(
          await secure.readSecretStringWithOptions(
            'splitz_bill_key_fresh@account-a',
          ),
          'FRESH',
        );
        expect(await raw.read(key: 'splitz_bill_key_b1'), before);
      });

      test('still refuses over any other secret it cannot open', () async {
        await leaveUnderP0(kPaymentLinkRecoveryStorageKey);
        await expectLater(
          secure.changePassword(currentPassword: p1, newPassword: p2),
          throwsA(isA<StateError>()),
        );
        secure.clearSessionPassword();
        expect(await secure.verifyPassword(p1), isTrue);
      });
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
