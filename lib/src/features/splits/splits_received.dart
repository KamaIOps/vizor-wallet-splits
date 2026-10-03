/// What this account has received, as the splits screens match it to bills.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:splitz_core/host.dart'
    show IncomingTransaction, txidInSendOrder;
import 'package:splitz_core/splitz_core.dart' show canonicalInstant;
import 'package:splitz_host/splitz_host.dart' show OwnTransaction;

import '../../core/storage/wallet_paths.dart';
import '../../providers/rpc_endpoint_provider.dart';
import '../../rust/api/sync.dart' as rust_sync;
import 'ui/state/splits_controller.dart' show HeldTransaction;

/// Every mined transaction that left this account with more than it had,
/// with what it brought.
///
/// A transaction still in the mempool, or one that expired unmined, is left
/// out: it may never land, and a confirmation written on it would settle a
/// debt nothing settled (§14.7). What it brought is the account's balance
/// change: §14.7 asks for the transaction's outputs to this account, and a
/// payment from somebody else spends none of this account's notes, so the
/// two are one figure. A transaction that also spent from this account is
/// one of its own, never a payer's.
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

/// The transactions this account built itself, each with the §9.3 instant the
/// wallet stamped on it, in the byte order a send reports: what an unanswered
/// send is checked against before a person may say nothing went out (§14.3).
///
/// `createdTime` is the wallet's own creation stamp in Unix seconds, and zero
/// for a transaction it only received, which is left out. An expired one can
/// no longer have paid anybody and is left out too.
Future<List<OwnTransaction>> splitsOwnTransactions({
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
      if (tx.createdTime > BigInt.zero && !tx.expiredUnmined)
        OwnTransaction(
          txid: txidForDisplay(tx.txidHex),
          created: canonicalInstant(
            DateTime.fromMillisecondsSinceEpoch(
              tx.createdTime.toInt() * 1000,
              isUtc: true,
            ).toIso8601String(),
          ),
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

/// [storedHex] — a transaction id as the wallet's history keeps it, in the
/// order its digest is computed in — in the order a send reports it and a
/// payment record carries it (§14.7, the host's [txidInSendOrder]). The
/// history hex-encodes the id as stored (`transactions.rs`,
/// `hex::encode(&base.txid)`), so without this no record would ever match
/// what arrived. An id that is not 64 hex digits is returned lower-cased.
String txidForDisplay(String storedHex) =>
    txidInSendOrder(storedHex) ?? storedHex.toLowerCase();
