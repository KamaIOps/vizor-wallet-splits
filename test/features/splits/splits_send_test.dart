import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/send/services/send_flow.dart';
import 'package:zcash_wallet/src/features/splits/splits_send.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' show PaymentUriOutput;

void main() {
  group("this wallet's broadcast as §14.3's outcomes", () {
    test('sent carries its transaction', () {
      final outcome = splitsSendOutcome(
        const SendBroadcastOutcome(
          phase: SendBroadcastPhase.succeeded,
          proposalConsumed: true,
          txid: 'cd34',
        ),
      );
      expect(
        (outcome.phase, outcome.txid),
        (WalletSendPhase.succeeded, 'cd34'),
      );
    });

    test('built and not broadcast keeps the transaction it built', () {
      final outcome = splitsSendOutcome(
        const SendBroadcastOutcome(
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

    test('aborted is a failure, not a send that may still land', () {
      final outcome = splitsSendOutcome(
        const SendBroadcastOutcome(
          phase: SendBroadcastPhase.aborted,
          proposalConsumed: false,
          error: 'cancelled',
        ),
      );
      expect(
        (outcome.phase, outcome.error),
        (WalletSendPhase.failed, 'cancelled'),
      );
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

  group("this wallet's reading, held against the request (§14.6)", () {
    test('the same payments, in any order, pass', () {
      expect(
        proposalProblem(
          _request,
          splitsReading([_read('u1ben', 9246), _read('u1ana', 7004)]),
        ),
        isNull,
      );
    });

    test('a reader that kept only the first payment is refused', () {
      expect(
        proposalProblem(_request, splitsReading([_read('u1ana', 7004)])),
        contains('Nothing was sent'),
      );
    });

    test('an amount past what an integer holds matches nothing', () {
      final reading = splitsReading([
        PaymentUriOutput(address: 'u1ana', zatoshi: BigInt.two.pow(70)),
      ]);
      expect(reading.single.zatoshi, -1);
    });
  });
}

final _request = protocol.renderUri(const [
  protocol.Zip321Payment(address: 'u1ana', zatoshi: 7004),
  protocol.Zip321Payment(address: 'u1ben', zatoshi: 9246),
]);

PaymentUriOutput _read(String address, int zatoshi) =>
    PaymentUriOutput(address: address, zatoshi: BigInt.from(zatoshi));
