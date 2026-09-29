import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/send/services/send_flow.dart';
import 'package:zcash_wallet/src/features/splits/splits_send.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' show PaymentUriOutput;

void main() {
  group('a splits send', () {
    test('refused before any transaction is built is a failure, not a send '
        'that may still land', () async {
      var broadcasts = 0;
      final outcome = await sendSplitsBatch<int>(
        propose: () async => throw StateError('insufficient funds'),
        broadcast: (_) async {
          broadcasts++;
          return const SendBroadcastOutcome(
            phase: SendBroadcastPhase.succeeded,
            proposalConsumed: true,
            txid: 'never',
          );
        },
      );
      expect(outcome.phase, WalletSendPhase.failed);
      expect(outcome.error, contains('insufficient funds'));
      expect(broadcasts, 0);
    });

    test('built and not broadcast keeps the transaction it built', () async {
      final outcome = await sendSplitsBatch<int>(
        propose: () async => 1,
        broadcast: (_) async => const SendBroadcastOutcome(
          phase: SendBroadcastPhase.pendingBroadcast,
          proposalConsumed: true,
          txid: 'ab12',
          statusMessage: 'stored, not broadcast',
        ),
      );
      expect(outcome.phase, WalletSendPhase.pendingBroadcast);
      expect(outcome.txid, 'ab12');
      expect(outcome.statusMessage, 'stored, not broadcast');
    });

    test('sent carries its transaction', () async {
      final outcome = await sendSplitsBatch<int>(
        propose: () async => 1,
        broadcast: (_) async => const SendBroadcastOutcome(
          phase: SendBroadcastPhase.succeeded,
          proposalConsumed: true,
          txid: 'cd34',
        ),
      );
      expect(outcome.phase, WalletSendPhase.succeeded);
      expect(outcome.txid, 'cd34');
    });
  });

  test('a reset deletes every bill on the device', () async {
    final root = await Directory.systemTemp.createTemp('splits-reset');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final splits = Directory('${root.path}/splits');
    await File('${splits.path}/splitz_bill_x').create(recursive: true);

    await deleteSplitsDirectory(resolveDirectory: () async => splits.path);
    expect(await splits.exists(), isFalse);

    // Nothing there is not a failure.
    await deleteSplitsDirectory(resolveDirectory: () async => splits.path);
  });

  group('what the wallet read is held against the request (§14.6)', () {
    test('the same payments, in any order, pass', () {
      expect(
        splitsProposalMismatch(_request, [
          _read('u1ben', 9246),
          _read('u1ana', 7004),
        ]),
        isNull,
      );
    });

    test('a reader that kept only the first payment is refused', () {
      expect(
        splitsProposalMismatch(_request, [_read('u1ana', 7004)]),
        contains('Nothing was sent'),
      );
    });

    test('a request this protocol did not write is refused in words', () {
      expect(
        splitsProposalMismatch('zcash:u1ana?amount=1&foo=bar', [
          _read('u1ana', 100000000),
        ]),
        protocol.describeCode('zip321_not_canonical'),
      );
    });

    test('a refusal spends nothing: no proposal is built', () async {
      var proposed = 0;
      final outcome = await sendSplitsBatch<int>(
        verify: () async => 'read differently',
        propose: () async => ++proposed,
        broadcast: (_) async => throw StateError('never broadcast'),
      );
      expect(outcome.phase, WalletSendPhase.failed);
      expect(outcome.error, 'read differently');
      expect(proposed, 0);
    });
  });
}

final _request = protocol.renderUri(const [
  protocol.Zip321Payment(address: 'u1ana', zatoshi: 7004),
  protocol.Zip321Payment(address: 'u1ben', zatoshi: 9246),
]);

PaymentUriOutput _read(String address, int zatoshi) =>
    PaymentUriOutput(address: address, zatoshi: BigInt.from(zatoshi));
