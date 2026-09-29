/// What this account has received, as the splits screens match it to bills.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:splitz_core/host.dart' show IncomingTransaction;

import '../../core/storage/wallet_paths.dart';
import '../../providers/rpc_endpoint_provider.dart';
import '../../rust/api/sync.dart' as rust_sync;

/// Every mined transaction that left this account with more than it had,
/// with what it brought.
///
/// A transaction still in the mempool, or one that expired unmined, is left
/// out: it may never land, and a confirmation written on it would settle a
/// debt nothing settled. What it brought is the account's balance change, so
/// a transaction that also spent from this account counts only its net.
Future<List<IncomingTransaction>> splitsReceived({
  required WidgetRef ref,
  required String accountUuid,
}) async {
  final history = await rust_sync.getTransactionHistory(
    dbPath: await getWalletDbPath(),
    network: ref.read(rpcEndpointProvider).networkName,
    accountUuid: accountUuid,
  );
  return [
    for (final tx in history)
      if (tx.minedHeight > BigInt.zero &&
          !tx.expiredUnmined &&
          tx.accountBalanceDelta > 0)
        IncomingTransaction(
          txidForDisplay(tx.txidHex),
          tx.accountBalanceDelta.toInt(),
        ),
  ];
}

/// Every transaction id this account's history holds, in the byte order a
/// send reports: what a pasted id is compared with to learn its order.
Future<Set<String>> splitsKnownTxids({
  required WidgetRef ref,
  required String accountUuid,
}) async {
  final history = await rust_sync.getTransactionHistory(
    dbPath: await getWalletDbPath(),
    network: ref.read(rpcEndpointProvider).networkName,
    accountUuid: accountUuid,
  );
  return {for (final tx in history) txidForDisplay(tx.txidHex)};
}

/// [storedHex], a transaction id as the history encodes its stored bytes, in
/// the byte-reversed form a send reports and a payment record carries.
///
/// The history hex-encodes the id as stored (`transactions.rs`,
/// `hex::encode(&base.txid)`); a send reports it as `TxId` displays it, which
/// reverses the bytes (zcash_protocol `TxId::as_hex`). Without this no record
/// would ever match what arrived.
String txidForDisplay(String storedHex) {
  final bytes = <String>[
    for (var i = 0; i + 2 <= storedHex.length; i += 2)
      storedHex.substring(i, i + 2),
  ];
  return bytes.reversed.join().toLowerCase();
}
