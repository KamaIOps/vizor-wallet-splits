import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_host/splitz_host.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/send/services/send_flow.dart';
import 'package:zcash_wallet/src/features/splits/splits_send.dart';

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
}
