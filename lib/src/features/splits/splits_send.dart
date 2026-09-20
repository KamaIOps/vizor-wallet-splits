/// Settling a bill: one payment request, one transaction.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:splitz_host/splitz_host.dart';

import '../../core/storage/wallet_paths.dart';
import '../../rust/api/sync.dart' as rust_sync;
import '../send/services/send_flow.dart';
import '../../providers/sync_provider.dart';
import '../../providers/rpc_endpoint_provider.dart';

/// Proposes a transaction for [paymentRequestUri] and broadcasts it.
///
/// The request may name several recipients — ZIP 321 indexes them — and all of
/// them are paid by one transaction, so a payer settling debts to four people
/// signs once and pays one fee.
///
/// Wrapped in `runWithAuthoritativeSpendable` exactly as an ordinary send is:
/// a proposal made against a balance the wallet is not yet sure of is a
/// proposal that can be refused at broadcast, after the person has confirmed
/// it.
Future<WalletSendOutcome> proposeAndBroadcastSplitsBatch({
  required WidgetRef ref,
  required String accountUuid,
  required String sendFlowId,
  required String paymentRequestUri,
}) async {
  final syncNotifier = ref.read(syncProvider.notifier);

  final proposal = await syncNotifier.runWithAuthoritativeSpendable(
    accountUuid: accountUuid,
    operation: () async {
      final dbPath = await getWalletDbPath();
      final endpoint = ref.read(rpcEndpointProvider);
      return rust_sync.proposeSendMulti(
        dbPath: dbPath,
        network: endpoint.networkName,
        accountUuid: accountUuid,
        sendFlowId: sendFlowId,
        paymentUri: paymentRequestUri,
      );
    },
  );

  // `SendReviewArgs` describes a single recipient, because the wallet's own
  // send flow has exactly one. Only the proposal id, the flow id and the
  // account drive execution; the address and amount are display metadata that
  // the splits screens do not read. They carry the batch's own figures so that
  // nothing downstream can show a value the transaction contradicts.
  final args = SendReviewArgs(
    proposalId: proposal.proposalId,
    sendFlowId: sendFlowId,
    proposalAccountUuid: accountUuid,
    address: '${_recipientCount(paymentRequestUri)} recipients',
    addressType: 'unified',
    amountZatoshi: _totalZatoshi(paymentRequestUri),
    feeZatoshi: proposal.feeZatoshi,
    needsSaplingParams: proposal.needsSaplingParams,
  );

  final outcome = await runSendBroadcast(
    ref: ref,
    args: args,
    confirmSaplingParamsDownload: () async => true,
  );

  return switch (outcome.phase) {
    SendBroadcastPhase.succeeded => WalletSendOutcome(
        phase: WalletSendPhase.succeeded,
        txid: outcome.txid,
      ),
    // Built and signed, not handed to the network. It may still land, so it is
    // neither paid nor unpaid: the bill records nothing and no retry is safe
    // until the wallet says which way it went.
    SendBroadcastPhase.pendingBroadcast => WalletSendOutcome(
        phase: WalletSendPhase.pendingBroadcast,
        statusMessage: outcome.statusMessage,
      ),
    SendBroadcastPhase.failed ||
    SendBroadcastPhase.aborted =>
      WalletSendOutcome(phase: WalletSendPhase.failed, error: outcome.error),
  };
}

/// How many recipients [paymentRequestUri] names.
///
/// ZIP 321 spells the first payment's address as `address` and the rest as
/// `address.1`, `address.2` and so on, so counting them needs no parser.
///
/// Display only. The transaction is built by Rust from the URI itself, so a
/// wrong count here would show a wrong number beside a right transaction
/// rather than send the wrong money.
int _recipientCount(String paymentRequestUri) =>
    RegExp(r'[?&]address(\.\d+)?=').allMatches(paymentRequestUri).length + 1;

/// What [paymentRequestUri] asks for in total, in zatoshi.
///
/// Display only, as [_recipientCount] is. Amounts in ZIP 321 are decimal ZEC;
/// they are read here as integers scaled by 10^8 rather than through a double,
/// because a double cannot hold every zatoshi of a large figure exactly.
BigInt _totalZatoshi(String paymentRequestUri) {
  var total = BigInt.zero;
  for (final match
      in RegExp(r'[?&]amount(?:\.\d+)?=([0-9.]+)').allMatches(paymentRequestUri)) {
    final parts = match.group(1)!.split('.');
    final whole = BigInt.tryParse(parts[0].isEmpty ? '0' : parts[0]);
    final fraction = parts.length > 1
        ? BigInt.tryParse(parts[1].padRight(8, '0').substring(0, 8))
        : BigInt.zero;
    if (whole == null || fraction == null) continue;
    total += whole * BigInt.from(100000000) + fraction;
  }
  return total;
}
