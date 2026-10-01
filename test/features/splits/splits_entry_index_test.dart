// The Split a bill screen for an account created or imported in this
// session, which the account list does not yet carry a ZIP-32 index for.
// Only the Rust FFI and the platform channels are faked.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/features/splits/splits_entry_screen.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_failover_provider.dart';
import 'package:zcash_wallet/src/rust/api/wallet.dart' as rw;
import 'package:zcash_wallet/src/rust/frb_generated.dart';

const _mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';
const _restart = 'Restart the wallet to open your bills.';

final _rust = _Fake();

AppBootstrapState _bootstrap(AccountState accounts) => AppBootstrapState(
  initialLocation: '/home',
  initialAccountState: accounts,
  initialSyncSnapshot: AppSyncSnapshot.emptyForAccount(
    accounts.activeAccountUuid ?? 'none',
  ),
  network: kZcashDefaultNetworkName,
  rpcEndpointConfig: defaultRpcEndpointConfig(kZcashDefaultNetworkName),
  themeMode: ThemeMode.system,
  privacyModeEnabled: false,
  isPasswordConfigured: true,
  isUnlocked: true,
  passwordRotationRecoveryFailed: false,
);

ProviderContainer _container(AccountState initial) => ProviderContainer(
  overrides: [
    appBootstrapProvider.overrideWithValue(_bootstrap(initial)),
    rpcEndpointFailoverLatestBlockHeightGetterProvider.overrideWithValue(
      (_, _) async => BigInt.from(3000000),
    ),
  ],
);

Future<void> _pumpUntil(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 40 && !done(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await t.pump();
  }
}

Future<String?> _shown(WidgetTester t, ProviderContainer c) async {
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: SplitsEntryScreen()),
    ),
  );
  String? found() {
    return find.text(_restart).evaluate().isNotEmpty ? _restart : null;
  }

  await _pumpUntil(t, () => found() != null);
  // Drain what the screen left queued in this test's zone (the secret store's
  // lock is released there), so the next test's read is not stuck behind it.
  for (var i = 0; i < 5; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await t.pump();
  }
  return found();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    RustLib.initMock(api: _rust);
    FlutterSecureStorage.setMockInitialValues({});
    support = Directory.systemTemp.createTempSync('splits-entry-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => support.path);
  });
  tearDownAll(() {
    RustLib.dispose();
    support.deleteSync(recursive: true);
  });
  setUp(() => AppSecureStore.instance.setSessionPassword('Pass1234!'));

  rw.AccountInfo row(String uuid, int? index) => rw.AccountInfo(
    uuid: uuid,
    name: uuid,
    unifiedAddress: 'u1$uuid',
    birthdayHeight: 2000000,
    zip32AccountIndex: index,
    isSeedAnchor: false,
    isHardware: false,
  );

  late AccountState created;

  test('a created account is listed with no index in this session', () async {
    final c = _container(const AccountState());
    addTearDown(c.dispose);
    await c.read(accountProvider.future);
    await c
        .read(accountProvider.notifier)
        .createAccountFromMnemonic(mnemonic: _mnemonic);
    created = c.read(accountProvider).value!;
    expect(created.accounts.single.zip32AccountIndex, isNull);
  });

  testWidgets('an account the database lists opens its bills', (t) async {
    final uuid = created.activeAccountUuid!;
    _rust.listed = [row(uuid, 0)];
    final c = _container(created);
    addTearDown(c.dispose);
    expect(await _shown(t, c), isNull);
    // The bill directory is made only once the identity is derived.
    expect(Directory('${support.path}/splits/$uuid').existsSync(), isTrue);
    await t.pumpWidget(const SizedBox());
    while (t.takeException() != null) {}
  });

  group('the index the database lists', () {
    test('is the one for this account', () async {
      expect(
        await listedZip32Index('b', () async => [row('a', 0), row('b', 2)]),
        2,
      );
    });
    test('is null when this account is not listed', () async {
      expect(await listedZip32Index('c', () async => [row('a', 0)]), isNull);
    });
    test('is null when it is listed without one', () async {
      expect(await listedZip32Index('a', () async => [row('a', null)]), isNull);
    });
    test('is null when the database cannot be read', () async {
      expect(
        await listedZip32Index('a', () async => throw StateError('locked')),
        isNull,
      );
    });
  });
}

class _Fake implements RustLibApi {
  int? importedAtIndex;

  /// What the wallet database lists, as `list_accounts` returns it; null
  /// makes the call fail.
  List<rw.AccountInfo>? listed = const [];

  @override
  Future<List<rw.AccountInfo>> crateApiWalletListAccounts({
    required String dbPath,
    required String network,
  }) async => listed ?? (throw StateError('database unreadable'));

  @override
  Future<rw.WalletImportResult> crateApiWalletImportWallet({
    required String mnemonic,
    required String bip39Passphrase,
    BigInt? birthdayHeight,
    required String network,
    required String dbPath,
    String? accountName,
  }) async => const rw.WalletImportResult(
    unifiedAddress: 'u1created',
    accountUuid: 'created-uuid',
  );

  @override
  Future<rw.SoftwareWalletImportAccount>
  crateApiWalletImportSoftwareAccountAtIndex({
    required String mnemonic,
    required String bip39Passphrase,
    BigInt? birthdayHeight,
    required String network,
    required String dbPath,
    required String name,
    required int zip32AccountIndex,
    required bool isFirstWalletAccount,
  }) async {
    importedAtIndex = zip32AccountIndex;
    return rw.SoftwareWalletImportAccount(
      accountUuid: 'linked-uuid',
      unifiedAddress: 'u1linked',
      zip32AccountIndex: zip32AccountIndex,
      name: name,
      isSeedAnchor: false,
    );
  }

  @override
  Future<String> crateApiSecretDeriveSecretPasswordVerifier({
    required String password,
    required String saltBase64,
  }) async => '$password:$saltBase64';

  @override
  Future<String> crateApiSecretEncryptSecretPayload({
    required List<int> plainBytes,
    required String password,
    required String saltBase64,
  }) async => jsonEncode({
    'v': 1,
    'n': base64Encode(utf8.encode('nonce')),
    'c': base64Encode(plainBytes),
    'm': base64Encode(utf8.encode('mac')),
  });

  @override
  Future<Uint8List> crateApiSecretDecryptSecretPayload({
    required String payloadJson,
    required String password,
    required String saltBase64,
  }) async => Uint8List.fromList(
    base64Decode((jsonDecode(payloadJson) as Map)['c'] as String),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
