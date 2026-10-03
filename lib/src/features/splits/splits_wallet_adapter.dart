/// What `package:splitz_host` asks for, answered by this wallet.
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
///
/// Per account: [accountUuid] is appended to every name (`<name>@<uuid>`), so
/// one account's bill keys are never another's, and removing an account can
/// find everything it kept. Every name still begins `splitz_`, which is what a
/// passcode change re-encrypts.
///
/// A name written before accounts were kept apart is read once and copied
/// under this account. Otherwise an existing identity seed would read as
/// absent and a new one would be minted, changing who this person is on
/// every bill they are on. The old name is deleted when it already named
/// this account (an identity seed); a bill key under it was shared by every
/// account, as `adoptLegacySplits` shares the bills, so it stays for the
/// others until a bill is forgotten.
class KeychainSecretStore implements SecretStore {
  KeychainSecretStore({required this.accountUuid, AppSecureStore? store})
    : _store = store ?? AppSecureStore.instance;

  final String accountUuid;
  final AppSecureStore _store;

  String _name(String key) => '$key@$accountUuid';

  @override
  Future<String?> read(String key) async {
    final held = await _store.readSecretStringWithOptions(_name(key));
    if (held != null) return held;
    final legacy = await _store.readSecretStringWithOptions(key);
    if (legacy == null) return null;
    await _store.writeSecretString(_name(key), legacy);
    if (key.endsWith(accountUuid)) await _store.delete(key);
    return legacy;
  }

  @override
  Future<void> write(String key, String value) =>
      _store.writeSecretString(_name(key), value);

  @override
  Future<void> delete(String key) async {
    await _store.delete(_name(key));
    await _store.delete(key);
  }
}

/// Forgets every bill in [store] whose key [keyOf] no longer reads, and
/// answers how many.
///
/// For bills just adopted from the layout every account shared: forgetting
/// one there deleted its shared key for every account, so a copy taken
/// afterwards is a bill no account can open. A keychain that refuses to read
/// while the session is locked has not said a key is gone, and that bill is
/// kept.
Future<int> forgetBillsWithoutKeys(
  BillStore store,
  Future<String?> Function(String billId) keyOf,
) async {
  var forgotten = 0;
  for (final billId in await store.billIds()) {
    try {
      if (await keyOf(billId) != null) continue;
    } on StateError {
      continue;
    }
    await store.forget(billId);
    forgotten++;
  }
  return forgotten;
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

/// Vizor, as `package:splitz_host` needs it.
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
       secrets = secrets ?? KeychainSecretStore(accountUuid: accountUuid),
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
