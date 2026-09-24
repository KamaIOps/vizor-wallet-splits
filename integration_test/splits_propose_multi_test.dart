/// `propose_send_multi`, run for real on a device.
///
/// Proposing is not spending: it selects inputs, builds a transaction and
/// stores a proposal, and nothing leaves the device until a broadcast. So the
/// whole path down into Rust can be exercised without a signature, which is
/// where a lane stops until somebody decides to send money.
///
/// The account here is not funded, so the answer is a refusal. What that
/// proves is the part that had never been proved: that the call is reached,
/// that the request parses, and that it refuses for the reason it should
/// rather than for a malformed request.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import 'support/mobile_regtest_flow.dart';

// Real mainnet unified addresses, from the splitz conformance corpus, which
// pins them against librustzcash's own reader.
const _recipientA =
    'u13j3q8q8f9hx2nx0w9l52dqksy4png7fgm0lqjh8ahn9enyvz5z9xnwzdcdjmpf756s2y88rnyr9px4f4k9w03sl6fr4vwsqcvg8ggfjx';
const _recipientB =
    'u16cynw2u6nshm44gjv9vy9dvav6zvvksphexzjs3tjke8mr3p942er0pu8held7zy7wpjxzqgkpdrjzd72h7pwf34df8a0xcv0su3acx7';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('a two-recipient request reaches Rust and is answered', (
    tester,
  ) async {
    tolerateRenderOverflows();
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) return;
      defaultHandler?.call(details);
    };

    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await createWalletWithPasscode(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    final accountUuid = container
        .read(accountProvider)
        .value!
        .activeAccountUuid!;
    final dbPath = await getWalletDbPath();
    final network = container.read(rpcEndpointProvider).networkName;

    Future<String> propose(String uri) async {
      try {
        final proposal = await rust_sync.proposeSendMulti(
          dbPath: dbPath,
          network: network,
          accountUuid: accountUuid,
          sendFlowId: 'splits-test-${DateTime.now().microsecondsSinceEpoch}',
          paymentUri: uri,
        );
        // Nothing is broadcast here. A proposal that did build holds its
        // inputs locked, so it is released rather than left behind.
        await rust_sync.discardProposal(
          proposalId: proposal.proposalId,
          sendFlowId: 'splits-test',
        );
        return 'proposed';
      } on Object catch (e) {
        return e.toString();
      }
    }

    // A request naming two recipients, as a settled bill produces.
    //
    // `propose_send_inner` checks the wallet's transaction version before it
    // builds the request and long before it selects inputs, and that check
    // refuses with "must sync" until the sync completion event has been
    // applied. Accepting that answer here would pass with input selection
    // entirely broken, so it is retried until the guard clears and only the
    // answer from behind it is asserted on.
    const uri =
        'zcash:$_recipientA?amount=0.0878323'
        '&address.1=$_recipientB&amount.1=0.5';
    var twoRecipients = await propose(uri);
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (twoRecipients.toLowerCase().contains('sync') &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 750));
      twoRecipients = await propose(uri);
    }
    logE2e('two recipients: $twoRecipients');
    // Unfunded, so it cannot be built — but it got far enough to say so, which
    // means the request parsed and input selection ran.
    expect(
      twoRecipients.toLowerCase(),
      anyOf(contains('fund'), contains('balance')),
      reason:
          'it should fail for want of money — not for a bad request, and '
          'not for the sync guard that sits in front of input selection',
    );

    // And the guard in front of it still refuses what cannot be settled, from
    // inside the running app rather than from a unit test.
    final noAmount = await propose(
      'zcash:$_recipientA?amount=0.0878323&address.1=$_recipientB',
    );
    logE2e('recipient with no amount: $noAmount');
    expect(noAmount, contains('has no amount'));

    final notARequest = await propose('not a payment request');
    logE2e('not a request: $notARequest');
    expect(notARequest, contains('Bad payment request'));

    logE2e('propose multi: done');
  });
}
