/// Settling a bill: one payment request, one transaction.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;
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
  return sendSplitsBatch(
    // What this wallet reads from the request is held against the request
    // before anything is built (§14.6): a reader that kept fewer payments
    // would sign less than the payer was shown.
    verify: () async => splitsProposalMismatch(
      paymentRequestUri,
      await rust_sync.paymentUriOutputs(paymentUri: paymentRequestUri),
    ),
    propose: () => syncNotifier.runWithAuthoritativeSpendable(
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
    ),
    broadcast: (proposal) => _broadcast(
      ref: ref,
      proposal: proposal,
      accountUuid: accountUuid,
      sendFlowId: sendFlowId,
      paymentRequestUri: paymentRequestUri,
    ),
  );
}

/// Proposes, then broadcasts, and says which of §14.3's outcomes occurred.
///
/// A proposal that is refused — too little to spend, an address the wallet
/// cannot pay — builds no transaction, so nothing can land. It is reported as
/// failed rather than raised: a raise leaves the send looking as though it
/// may still reach the network, and that blocks every later one.
Future<WalletSendOutcome> sendSplitsBatch<P>({
  required Future<P> Function() propose,
  required Future<SendBroadcastOutcome> Function(P proposal) broadcast,
  Future<String?> Function()? verify,
}) async {
  // Before anything is built, so a refusal here spends nothing (§14.3).
  if (verify != null) {
    final String? why;
    try {
      why = await verify();
    } on Object catch (error) {
      return WalletSendOutcome(
        phase: WalletSendPhase.failed,
        error: 'The wallet could not read this payment: $error',
      );
    }
    if (why != null) {
      return WalletSendOutcome(phase: WalletSendPhase.failed, error: why);
    }
  }
  final P proposal;
  try {
    proposal = await propose();
  } on Object catch (error) {
    return WalletSendOutcome(
      phase: WalletSendPhase.failed,
      error: 'The wallet could not build this payment: $error',
    );
  }
  final outcome = await broadcast(proposal);
  return switch (outcome.phase) {
    SendBroadcastPhase.succeeded => WalletSendOutcome(
      phase: WalletSendPhase.succeeded,
      txid: outcome.txid,
    ),
    // Built and signed, not handed to the network. It may still land, so it
    // is neither paid nor unpaid: the bill records nothing and no retry is
    // safe until the wallet says which way it went. The transaction it built
    // is what a person looks up to learn which way.
    SendBroadcastPhase.pendingBroadcast => WalletSendOutcome(
      phase: WalletSendPhase.pendingBroadcast,
      statusMessage: outcome.statusMessage,
      txid: outcome.txid,
    ),
    SendBroadcastPhase.failed || SendBroadcastPhase.aborted =>
      WalletSendOutcome(phase: WalletSendPhase.failed, error: outcome.error),
  };
}

Future<SendBroadcastOutcome> _broadcast({
  required WidgetRef ref,
  required rust_sync.ProposalResult proposal,
  required String accountUuid,
  required String sendFlowId,
  required String paymentRequestUri,
}) {
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

  return runSendBroadcast(
    ref: ref,
    args: args,
    confirmSaplingParamsDownload: () async => true,
  );
}

/// Why the payments this wallet read from [paymentRequestUri] are not the ones
/// it asks for, or null when they are (§14.6).
///
/// [read] is what the wallet's own ZIP 321 reader produced — the reading a
/// proposal is built from. A request this protocol did not write is refused
/// with its code's sentence.
String? splitsProposalMismatch(
  String paymentRequestUri,
  List<rust_sync.PaymentUriOutput> read,
) {
  final splitz.ProposalCheck check;
  try {
    check = splitz.checkProposal(paymentRequestUri, [
      for (final o in read)
        // An amount past what an integer holds cannot match any payment.
        splitz.ProposedOutput(
          o.address,
          o.zatoshi.isValidInt ? o.zatoshi.toInt() : -1,
        ),
    ]);
  } on protocol.SplitError catch (e) {
    return protocol.describeCode(e.code) ?? e.code;
  }
  if (check.matches) return null;
  return 'Your wallet read this payment differently. Nothing was sent.';
}
