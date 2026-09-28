/// What `package:splitz_wallet` asks for, answered by this wallet.
///
/// The package names no wallet and depends on none: it declares what it needs
/// as interfaces, and this file is where those meet Vizor's own APIs. Keeping
/// the meeting in one file is what lets the package be lifted into another
/// wallet unchanged.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:splitz_host/splitz_host.dart';

import '../../core/storage/app_secure_store.dart';

/// The wallet's keychain, as the package's `SecretStore`.
///
/// Bill keys and this account's signing identity live here rather than beside
/// the bills: a bill key in ordinary storage is a bill key anything that can
/// read the app's sandbox can use.
class KeychainSecretStore implements SecretStore {
  KeychainSecretStore({AppSecureStore? store})
    : _store = store ?? AppSecureStore.instance;

  final AppSecureStore _store;

  @override
  Future<String?> read(String key) => _store.readSecretStringWithOptions(key);

  @override
  Future<void> write(String key, String value) =>
      _store.writeSecretString(key, value);

  @override
  Future<void> delete(String key) => _store.delete(key);
}

/// Proposes and broadcasts one transaction for a whole payment request.
///
/// Two calls, and they must stay two: proposing takes the wallet's write lock
/// and locks the inputs it selected, and broadcasting is irreversible. What
/// sits between them is where a person can still walk away.
typedef ProposeAndBroadcast =
    Future<WalletSendOutcome> Function(String paymentRequestUri);

/// This wallet's send path, as the package's `WalletSender`.
///
/// The work is passed in rather than done here because Vizor's broadcast needs
/// a `WidgetRef`, which belongs to a screen and not to a service. A screen
/// builds one of these with a closure that proposes and broadcasts, and the
/// package never learns that any of that happened.
class WalletSplitsSender implements WalletSender {
  const WalletSplitsSender({
    required ProposeAndBroadcast send,
    required String? payToAddress,
  }) : _send = send,
       _payToAddress = payToAddress;

  final ProposeAndBroadcast _send;
  final String? _payToAddress;

  /// Where this device is paid. Null is a state, not a failure: §8.5 says a
  /// participant with no address is reported as unpayable rather than dropped.
  @override
  String? get payToAddress => _payToAddress;

  @override
  Future<WalletSendOutcome> send(String paymentRequestUri) =>
      _send(paymentRequestUri);
}

/// Vizor, as `package:splitz_wallet` needs it.
class VizorSplitsWallet implements SplitsWallet {
  VizorSplitsWallet({
    required String accountUuid,
    required List<int>? identitySecret,
    required this.sender,
    SecretStore? secrets,
    Uint8List Function(int)? randomBytes,
    DateTime Function()? clock,
  }) : account = WalletAccount(
         id: accountUuid,
         // What makes this account's splits identity survive a reinstall:
         // derived from the mnemonic, so the same mnemonic yields the same
         // identity on a new device, while the account uuid is assigned by
         // the wallet database at import and does not.
         identitySecret: identitySecret,
       ),
       secrets = secrets ?? KeychainSecretStore(),
       _randomBytes = randomBytes,
       _clock = clock;

  @override
  final WalletAccount account;

  @override
  final WalletSender sender;

  @override
  final SecretStore secrets;

  final Uint8List Function(int)? _randomBytes;
  final DateTime Function()? _clock;

  @override
  DateTime now() => (_clock ?? () => DateTime.now().toUtc())();

  @override
  Uint8List randomBytes(int byteCount) =>
      (_randomBytes ?? _secureRandomBytes)(byteCount);

  /// §9.4 derives a bill's id from a nonce, so two bills opened in one second
  /// by one person are the same bill unless this is unpredictable.
  static Uint8List _secureRandomBytes(int byteCount) {
    final random = _random;
    return Uint8List.fromList(
      List<int>.generate(byteCount, (_) => random.nextInt(256)),
    );
  }

  static final _random = _secure();

  static math.Random _secure() => math.Random.secure();
}

/// The bytes a software account's splits identity is derived from: the
/// mnemonic and the BIP39 passphrase, UTF-8, joined by a zero byte, and for
/// any ZIP 32 account but the first, a zero byte and [accountIndex] as four
/// big-endian bytes.
///
/// The passphrase, because it selects a different wallet from one mnemonic;
/// the account index, because two accounts of one mnemonic are two people to
/// a bill, and one key would link them on every bill either joins. The zero
/// bytes because neither text may contain one, so no two inputs join to the
/// same bytes; account 0 keeps the form without an index, so its identity is
/// the one it already had. `splitz_host` hashes this under its own domain, so
/// the identity seed reveals nothing about the mnemonic.
List<int> splitsIdentitySecret({
  required String mnemonic,
  required String passphrase,
  int accountIndex = 0,
}) {
  if (accountIndex < 0 || accountIndex > 0x7fffffff) {
    throw RangeError.range(accountIndex, 0, 0x7fffffff, 'accountIndex');
  }
  return [
    ...utf8.encode(mnemonic),
    0,
    ...utf8.encode(passphrase),
    if (accountIndex != 0) ...[
      0,
      (accountIndex >> 24) & 0xff,
      (accountIndex >> 16) & 0xff,
      (accountIndex >> 8) & 0xff,
      accountIndex & 0xff,
    ],
  ];
}
