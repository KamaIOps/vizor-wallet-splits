// A later payment of something else from the same wallet does not hold an
// unanswered send's note (§14.3).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'settle_send_test.dart' show owingBen;
import 'support/fake_wallet.dart';

const _pending = WalletSendOutcome(phase: WalletSendPhase.pendingBroadcast);

void main() {
  for (final otherSendLater in [false, true]) {
    test('restart, otherSendLater=$otherSendLater', () async {
      final storage = InMemoryBillStorage();
      final secrets = InMemorySecretStore();
      final wallet = FakeWallet(outcome: _pending);
      final first = SplitsController(
        wallet: wallet,
        store: BillStore(storage),
        keys: SplitsKeys(store: secrets, random: Random(3)),
      );
      final id = await owingBen(first);
      await first.settle(id, (await first.obligation(id))!);
      final note = (await first.pendingSend(id))!;
      // The proof never finished: this send is in no history. An hour later
      // the person paid a shop from the same wallet.
      final unrelated = 'ab' * 32;
      final later = DateTime.parse(note.at).add(const Duration(hours: 1));
      final again = SplitsController(
        wallet: wallet,
        store: BillStore(storage),
        keys: SplitsKeys(store: secrets, random: Random(3)),
        held: () async =>
            otherSendLater ? {unrelated: HeldTransaction.mined} : const {},
        own: () async => otherSendLater
            ? [
                OwnTransaction(
                  sent: 2500000,
                  txid: unrelated,
                  created:
                      '${later.toUtc().toIso8601String().substring(0, 19)}Z',
                ),
              ]
            : const [],
      );
      await again.load();
      await again.resolveSend(id);
      final cleared = await again.pendingSend(id) == null;
      expect(again.lastError, isNull);
      expect(cleared, isTrue);
      // Nothing is recorded as paid: the shop's transaction is not this one.
      expect(again.bills.single.bill.payments, isEmpty);
      // And the debt is open to settle another way.
      await again.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
      expect(again.lastError, isNull);
    });
  }
}
