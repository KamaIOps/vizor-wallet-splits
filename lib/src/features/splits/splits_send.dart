/// Settling a bill: one payment request, one transaction.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_host/splitz_host.dart';

import '../../core/storage/wallet_paths.dart';
import 'splits_request_summary.dart';
import 'ui/state/splits_controller.dart' show SendPreview;
import 'ui/view/naming.dart' show formatZec, sendShortfall;
import '../../rust/api/sync.dart' as rust_sync;
import '../send/services/send_flow.dart';
import '../../providers/sync_provider.dart';
import '../../providers/rpc_endpoint_provider.dart';

/// Proposes a transaction for [paymentRequestUri] and broadcasts it, in the
/// order `sendPaymentRequest` keeps (§14.3, §14.6).
///
/// The request may name several recipients — ZIP 321 indexes them — and all of
/// them are paid by one transaction, so a payer settling debts to four people
/// signs once and pays one fee.
///
/// Wrapped in `runWithAuthoritativeSpendable` exactly as an ordinary send is:
/// a proposal made against a balance the wallet is not yet sure of is a
/// proposal that can be refused at broadcast, after the person has confirmed
/// it.
///
/// [reviewedFee] is the fee the person was shown, in zatoshi. A proposal whose
/// fee is higher is discarded and the send refused, with nothing built: notes
/// can change between the preview and the send, and a person confirms the
/// figure they saw, not one chosen after.
Future<WalletSendOutcome> proposeAndBroadcastSplitsBatch({
  required WidgetRef ref,
  required String accountUuid,
  required String sendFlowId,
  required String paymentRequestUri,
  int? reviewedFee,
}) async {
  final syncNotifier = ref.read(syncProvider.notifier);
  return sendPaymentRequest(
    uri: paymentRequestUri,
    read: () async => splitsReading(
      await rust_sync.paymentUriOutputs(paymentUri: paymentRequestUri),
    ),
    propose: () => syncNotifier.runWithAuthoritativeSpendable(
      accountUuid: accountUuid,
      operation: () async {
        final dbPath = await getWalletDbPath();
        final endpoint = ref.read(rpcEndpointProvider);
        final proposal = await rust_sync.proposeSendMulti(
          dbPath: dbPath,
          network: endpoint.networkName,
          accountUuid: accountUuid,
          sendFlowId: sendFlowId,
          paymentUri: paymentRequestUri,
        );
        final fee = proposal.feeZatoshi.toInt();
        if (reviewedFee != null && fee > reviewedFee) {
          try {
            await rust_sync.discardProposal(
              proposalId: proposal.proposalId,
              sendFlowId: sendFlowId,
            );
          } on Object catch (error) {
            debugPrint('splits: raised-fee proposal not discarded: $error');
          }
          throw FeeRaised(reviewed: reviewedFee, now: fee);
        }
        return proposal;
      },
    ),
    broadcast: (proposal) async => splitsSendOutcome(
      await _broadcast(
        ref: ref,
        proposal: proposal,
        accountUuid: accountUuid,
        sendFlowId: sendFlowId,
        paymentRequestUri: paymentRequestUri,
      ),
    ),
  );
}

/// A send refused before anything was built because its fee came out above
/// the one the person reviewed.
class FeeRaised implements Exception {
  const FeeRaised({required this.reviewed, required this.now});

  final int reviewed;
  final int now;

  @override
  String toString() =>
      'The fee went up from ${formatZec(reviewed)} to ${formatZec(now)} since '
      'you reviewed this payment. Nothing was sent; review it again.';
}

/// What sending [paymentRequestUri] would take, from a proposal built the way
/// [proposeAndBroadcastSplitsBatch] builds one — against the balance a sync
/// has settled — and then discarded: the fee, or that the account cannot
/// cover the request and its fee. Nothing is signed or broadcast.
///
/// The wallet states a shortfall as "Insufficient balance (have H, need N
/// including fee)"; any other refusal is an empty preview, and the send
/// itself reports it.
Future<SendPreview> previewSplitsBatch({
  required WidgetRef ref,
  required String accountUuid,
  required String paymentRequestUri,
}) async {
  final flow = 'splits-preview-${DateTime.now().microsecondsSinceEpoch}';
  final syncNotifier = ref.read(syncProvider.notifier);
  final rust_sync.ProposalResult proposal;
  try {
    // Against the same settled balance the send waits for, so a shortfall
    // said here is one the send would meet.
    proposal = await syncNotifier.runWithAuthoritativeSpendable(
      accountUuid: accountUuid,
      operation: () async => rust_sync.proposeSendMulti(
        dbPath: await getWalletDbPath(),
        network: ref.read(rpcEndpointProvider).networkName,
        accountUuid: accountUuid,
        sendFlowId: flow,
        paymentUri: paymentRequestUri,
      ),
    );
  } on Object catch (error) {
    final detail = '$error';
    if (!detail.toLowerCase().contains('insufficient')) {
      return const SendPreview();
    }
    final shortfall = sendShortfall(detail);
    return SendPreview(
      short: true,
      haveZatoshi: shortfall?.have,
      needZatoshi: shortfall?.need,
    );
  }
  try {
    await rust_sync.discardProposal(
      proposalId: proposal.proposalId,
      sendFlowId: flow,
    );
  } on Object catch (error) {
    debugPrint('splits: preview proposal not discarded: $error');
  }
  return SendPreview(feeZatoshi: proposal.feeZatoshi.toInt());
}

/// Whether a request naming [address] is one this wallet can send (§14.6):
/// its own ZIP 321 reader reads a one-output request to it, and the address
/// is valid on the network the wallet sends on. A request is read whole, so
/// one address failing either stops the payment to every other recipient.
Future<bool> splitsReadsAddress(WidgetRef ref, String address) async {
  try {
    await rust_sync.paymentUriOutputs(
      paymentUri: 'zcash:$address?amount=0.00000001',
    );
    final checked = await rust_sync.validateAddress(
      address: address,
      network: ref.read(rpcEndpointProvider).networkName,
    );
    return checked.isValid && !checked.wrongNetwork;
  } on Object {
    return false;
  }
}

/// What this wallet's ZIP 321 reader made of a request, as §14.6 compares it.
///
/// An amount past what an integer holds cannot match any payment, so it is
/// carried as one that matches nothing rather than dropped.
List<splitz.ProposedOutput> splitsReading(
  List<rust_sync.PaymentUriOutput> read,
) => [
  for (final o in read)
    splitz.ProposedOutput(
      o.address,
      o.zatoshi.isValidInt ? o.zatoshi.toInt() : -1,
    ),
];

/// This wallet's broadcast outcome as §14.3's three.
WalletSendOutcome splitsSendOutcome(SendBroadcastOutcome outcome) =>
    switch (outcome.phase) {
      SendBroadcastPhase.succeeded => WalletSendOutcome(
        phase: WalletSendPhase.succeeded,
        txid: outcome.txid,
      ),
      // Built and signed, not handed to the network. It may still land, so it
      // is neither paid nor unpaid: the bill records nothing and no retry is
      // safe until the wallet says which way it went. The transaction it
      // built is what a person looks up to learn which way.
      SendBroadcastPhase.pendingBroadcast => WalletSendOutcome(
        phase: WalletSendPhase.pendingBroadcast,
        statusMessage: outcome.statusMessage,
        txid: outcome.txid,
      ),
      SendBroadcastPhase.failed || SendBroadcastPhase.aborted =>
        WalletSendOutcome(phase: WalletSendPhase.failed, error: outcome.error),
    };

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
