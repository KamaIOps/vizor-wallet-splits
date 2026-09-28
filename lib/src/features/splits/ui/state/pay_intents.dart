/// Sends this device started and has not seen resolved.
library;

import 'dart:convert';

import 'package:splitz_host/splitz_host.dart';

/// One send from one bill, written down before the wallet was called.
///
/// A send the wallet reports as built-but-not-broadcast may still land, and
/// one interrupted by the app dying may have landed already. Either way the
/// bill holds no record of it, so without this the debt is offered again and
/// the same money goes out twice.
class PayIntent {
  const PayIntent({
    required this.billId,
    required this.uri,
    required this.carried,
    required this.at,
    this.swap,
    this.zatoshi,
    this.txid,
    this.sent = const {},
    this.rate,
  });

  final String billId;

  /// The ZIP 321 request handed to the wallet.
  final String uri;

  /// What the request pays each recipient, in minor units: what a record of
  /// this send carries once its transaction id is known.
  final Map<String, int> carried;

  /// When the send was started, as §9.3 renders an instant.
  final String at;

  /// The swap this send was the deposit for, or null for a payment request.
  ///
  /// A swap is recorded by the provider's reference rather than a Zcash
  /// transaction id, so resolving one needs no id from the person.
  final SwapWatch? swap;

  /// What the deposit sent, for a swap: the ZEC leg its record carries.
  final int? zatoshi;

  /// The transaction, when the wallet named one: the one a pending send
  /// built, or one that went out while its records could not be written —
  /// the bill was forgotten while the send was out.
  final String? txid;

  /// What the request sends each recipient, in zatoshi: the ZEC a record of
  /// this send states (§9.2).
  final Map<String, int> sent;

  /// The rate the request was priced at, as §9.1 writes one: what a record
  /// of this send states as `paidAtRate`.
  final Map<String, dynamic>? rate;

  /// This intent, with the transaction [id] it went out as.
  PayIntent sentAs(String? id) => PayIntent(
    billId: billId,
    uri: uri,
    carried: carried,
    at: at,
    swap: swap,
    zatoshi: zatoshi,
    txid: id,
    sent: sent,
    rate: rate,
  );

  Map<String, dynamic> toJson() => {
    'billId': billId,
    'uri': uri,
    'carried': carried,
    'at': at,
    if (swap != null) 'swap': swap!.toJson(),
    if (zatoshi != null) 'zatoshi': zatoshi,
    if (txid != null) 'txid': txid,
    if (sent.isNotEmpty) 'sent': sent,
    if (rate != null) 'rate': rate,
  };

  /// Null for anything this class did not write.
  static PayIntent? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final billId = json['billId'];
    final uri = json['uri'];
    final at = json['at'];
    final carried = json['carried'];
    if (billId is! String || uri is! String || at is! String) return null;
    if (carried is! Map<String, dynamic>) return null;
    final swapJson = json['swap'];
    final swap = swapJson == null ? null : SwapWatch.fromJson(swapJson);
    if (swapJson != null && swap == null) return null;
    final zatoshi = json['zatoshi'];
    if (zatoshi != null && zatoshi is! int) return null;
    final txid = json['txid'];
    if (txid != null && txid is! String) return null;
    final amounts = _ints(carried);
    if (amounts == null) return null;
    final sentJson = json['sent'] ?? const <String, dynamic>{};
    if (sentJson is! Map<String, dynamic>) return null;
    final sent = _ints(sentJson);
    if (sent == null) return null;
    final rate = json['rate'];
    if (rate != null && rate is! Map<String, dynamic>) return null;
    return PayIntent(
      billId: billId,
      uri: uri,
      carried: amounts,
      at: at,
      swap: swap,
      zatoshi: zatoshi as int?,
      txid: txid as String?,
      sent: sent,
      rate: rate as Map<String, dynamic>?,
    );
  }

  static Map<String, int>? _ints(Map<String, dynamic> json) {
    final out = <String, int>{};
    for (final e in json.entries) {
      final v = e.value;
      if (v is! int) return null;
      out[e.key] = v;
    }
    return out;
  }
}

/// The unresolved send for each bill, at most one per bill.
///
/// Kept in the bill storage under its own prefix, so it survives a restart
/// and a sweep of bills never reaches it.
class PayIntents {
  const PayIntents(this._storage);

  final BillStorage _storage;

  static const String _prefix = 'payintent/';

  String _key(String billId) => '$_prefix$billId';

  Future<void> put(PayIntent intent) =>
      _storage.write(_key(intent.billId), jsonEncode(intent.toJson()));

  Future<void> clear(String billId) => _storage.delete(_key(billId));

  /// The unresolved send for [billId], or null.
  ///
  /// **An entry that will not read still blocks.** Treating a damaged intent
  /// as absent would let the send it stands for go out a second time; it is
  /// reported with no amounts instead, and the person resolves it.
  Future<PayIntent?> of(String billId) async {
    final String? raw;
    try {
      raw = await _storage.read(_key(billId));
    } on BillStorageUnreadable {
      // Present and unreadable blocks exactly as damaged does.
      return PayIntent(billId: billId, uri: '', carried: const {}, at: '');
    }
    if (raw == null) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = null;
    }
    return PayIntent.fromJson(decoded) ??
        PayIntent(billId: billId, uri: '', carried: const {}, at: '');
  }
}
