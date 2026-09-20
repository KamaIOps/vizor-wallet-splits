/// What `package:splitz_wallet` asks for, answered by this wallet.
///
/// The package names no wallet and depends on none: it declares what it needs
/// as interfaces, and this file is where those meet Vizor's own APIs. Keeping
/// the meeting in one file is what lets the package be lifted into another
/// wallet unchanged.
library;

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
typedef ProposeAndBroadcast = Future<WalletSendOutcome> Function(
  String paymentRequestUri,
);

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
  })  : _send = send,
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
    required String? unifiedFullViewingKey,
    required this.sender,
    SecretStore? secrets,
    Uint8List Function(int)? randomBytes,
    DateTime Function()? clock,
  })  : account = WalletAccount(
          id: accountUuid,
          // What makes this account's splits identity survive a reinstall: a
          // viewing key is derived from the wallet seed, so the same mnemonic
          // yields the same identity on a new device, while the account uuid
          // is assigned by the wallet database at import and does not.
          viewingKey: unifiedFullViewingKey,
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
