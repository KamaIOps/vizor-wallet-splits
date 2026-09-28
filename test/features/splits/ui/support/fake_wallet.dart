import 'dart:typed_data';

import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_host/splitz_host.dart';

/// A wallet that does nothing, for tests that are not about the wallet.
///
/// The clock is held still and the randomness is a counter: §9.3 instants order
/// a log and §9.4 derives a bill id from a nonce, so a log that moves between
/// runs cannot be asserted against a fixed expectation.
/// A secret derived from the account id, standing in for a mnemonic's.
const Object _derived = Object();

class FakeWallet implements SplitsWallet {
  FakeWallet({
    String id = 'ana',
    String? payTo = 'u1ana000000000000000000',
    Object? identitySecret = _derived,
    WalletSendOutcome outcome = const WalletSendOutcome(
      phase: WalletSendPhase.succeeded,
      txid: 'tx-1',
    ),
  }) : account = WalletAccount(
         id: id,
         identitySecret: identical(identitySecret, _derived)
             ? 'secret-$id'.codeUnits
             : identitySecret as List<int>?,
       ),
       sender = FakeSender(payToAddress: payTo, outcome: outcome);

  @override
  final WalletAccount account;

  @override
  final FakeSender sender;

  @override
  final SecretStore secrets = InMemorySecretStore();

  DateTime _at = DateTime.utc(2026, 10, 28, 19, 30);
  int _counter = 0;

  /// Moves the clock on, so two entries written in one test are two entries and
  /// §10.2 has an order to put them in.
  void tick([Duration by = const Duration(minutes: 1)]) => _at = _at.add(by);

  @override
  DateTime now() => _at;

  @override
  Uint8List randomBytes(int byteCount) {
    _counter++;
    return Uint8List.fromList(
      List<int>.generate(byteCount, (i) => _counter + i),
    );
  }
}

class FakeSender implements WalletSender {
  FakeSender({required this.payToAddress, required this.outcome});

  @override
  final String? payToAddress;

  final WalletSendOutcome outcome;
  final List<String> sent = [];

  @override
  Future<WalletSendOutcome> send(String paymentRequestUri) async {
    sent.add(paymentRequestUri);
    return outcome;
  }
}

/// A 32-byte key in the encoding §9.4 wants, distinct per participant.
String fakeKey(String who) => splitz.base64UrlNoPad(
  List<int>.generate(splitz.creatorKeyBytes, (i) => who.codeUnitAt(0) + i),
);

/// A bill host speaking as somebody who is not this device.
///
/// Peers write their own entries; a test that wrote them through the device
/// under test would prove only that it agrees with itself. §10.7 binds an
/// entry to its author, so the author has to differ.
splitz.BillHost otherHost(String id, {String? payTo}) =>
    WalletBillHost(FakeWallet(id: id, payTo: payTo ?? 'u1$id'));

/// A peer who signs with its own key and speaks as the id that key derives
/// (§10.7), so the fold binds it: what a person joining from their own device
/// is. [host] writes its entries; [sign] signs one for a bill.
class SignedPeer {
  SignedPeer._(this.id, this.key, this.host);

  static Future<SignedPeer> named(String name, {String? payTo}) async {
    final signer = SplitsSigner();
    final seed = List<int>.generate(32, (i) => name.codeUnitAt(0) * 7 + i);
    final key = await signer.publicKeyFromSeed(seed);
    final id = splitz.participantId(key)!;
    final host = WalletBillHost(
      FakeWallet(id: name, payTo: payTo ?? 'u1$name'),
      me: id,
      sign: signer.signerFor(seed),
    );
    return SignedPeer._(id, key, host);
  }

  final String id;
  final String key;
  final WalletBillHost host;

  Future<Map<String, dynamic>> sign(
    Map<String, dynamic> entry,
    String billId,
  ) => splitz.signEntry(host: host, entry: entry, billId: billId);

  /// Their own join, carrying their key.
  Future<Map<String, dynamic>> join(
    String billId, {
    required String name,
    required String payTo,
  }) => sign(
    splitz.joinBill(host: host, name: name, payTo: payTo, identityKey: key),
    billId,
  );
}
