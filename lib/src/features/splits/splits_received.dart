/// What this account has received, as the splits screens match it to bills.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:splitz_core/host.dart' show IncomingTransaction;

import '../../core/storage/wallet_paths.dart';
import '../../providers/rpc_endpoint_provider.dart';
import '../../rust/api/sync.dart' as rust_sync;
import 'ui/state/splits_controller.dart' show HeldTransaction;

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

/// When each mined transaction that brought this account money was mined, by
/// id in the byte order a payment record carries.
Future<Map<String, DateTime>> splitsReceivedTimes({
  required WidgetRef ref,
  required String accountUuid,
}) async {
  final history = await rust_sync.getTransactionHistory(
    dbPath: await getWalletDbPath(),
    network: ref.read(rpcEndpointProvider).networkName,
    accountUuid: accountUuid,
  );
  return {
    for (final tx in history)
      if (tx.minedHeight > BigInt.zero &&
          !tx.expiredUnmined &&
          tx.accountBalanceDelta > 0 &&
          tx.blockTime > BigInt.zero)
        txidForDisplay(tx.txidHex): DateTime.fromMillisecondsSinceEpoch(
          tx.blockTime.toInt() * 1000,
          isUtc: true,
        ),
  };
}

/// The text memos each of [txids] brought this account, by id in the byte
/// order a payment record carries. A transaction whose detail does not read
/// is left out, which says its memos are unknown rather than none.
Future<Map<String, List<String>>> splitsReceivedMemos({
  required WidgetRef ref,
  required String accountUuid,
  required Set<String> txids,
}) async {
  final dbPath = await getWalletDbPath();
  final network = ref.read(rpcEndpointProvider).networkName;
  final history = await rust_sync.getTransactionHistory(
    dbPath: dbPath,
    network: network,
    accountUuid: accountUuid,
  );
  final out = <String, List<String>>{};
  for (final tx in history) {
    final id = txidForDisplay(tx.txidHex);
    if (!txids.contains(id)) continue;
    try {
      final detail = await rust_sync.getTransactionDetail(
        dbPath: dbPath,
        network: network,
        accountUuid: accountUuid,
        txidHex: tx.txidHex,
        txKind: tx.txKind,
      );
      final memo = detail.memo;
      out[id] = memo == null ? const [] : [memo];
    } on Object {
      continue;
    }
  }
  return out;
}

/// Where each transaction this account's history holds stands, by id in the
/// byte order a send reports: what a send left unresolved is checked against
/// before a person may say it did not go through.
Future<Map<String, HeldTransaction>> splitsHeldTransactions({
  required WidgetRef ref,
  required String accountUuid,
}) async {
  final history = await rust_sync.getTransactionHistory(
    dbPath: await getWalletDbPath(),
    network: ref.read(rpcEndpointProvider).networkName,
    accountUuid: accountUuid,
  );
  return {
    for (final tx in history)
      txidForDisplay(tx.txidHex): tx.minedHeight > BigInt.zero
          ? HeldTransaction.mined
          : tx.expiredUnmined
          ? HeldTransaction.expired
          : HeldTransaction.waiting,
  };
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
