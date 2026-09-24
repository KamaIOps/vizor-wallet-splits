/// Settling a bill: one payment request, one transaction.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:splitz_host/splitz_host.dart';

import '../../core/storage/wallet_paths.dart';
import 'splits_request_summary.dart';
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
    address: '${splitsRecipientCount(paymentRequestUri)} recipients',
    addressType: 'unified',
    amountZatoshi: splitsTotalZatoshi(paymentRequestUri),
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
    SendBroadcastPhase.failed || SendBroadcastPhase.aborted =>
      WalletSendOutcome(phase: WalletSendPhase.failed, error: outcome.error),
  };
}
