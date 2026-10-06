// A payer's own payments say what carried them, shortly; nobody else's list
// carries a reference.
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'methods_screens_test.dart' show billOwing;
import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show app, controllerFor;

final _txid = 'ab' * 32;

void main() {
  testWidgets('my own send shows its transaction, shortened', (t) async {
    final c = controllerFor(
      FakeWallet(
        outcome: WalletSendOutcome(
          phase: WalletSendPhase.succeeded,
          txid: _txid,
        ),
      ),
    );
    final id = await billOwing(c, other: 'ben');
    final owed = (await c.obligation(id))!;
    await c.settle(id, owed);
    expect(c.lastError, isNull);

    await t.pumpWidget(app(c, ActivityScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.textContaining('tx ${_txid.substring(0, 14)}…'), findsOne);
    expect(find.textContaining(_txid), findsNothing, reason: 'shortened');
  });

  testWidgets('somebody else’s payment shows no reference in the list', (
    t,
  ) async {
    final c = controllerFor(FakeWallet(id: 'ben', payTo: 'u1ben'));
    final id = await billOwing(c, other: 'ana');
    await c.accept(id, [
      entries.recordPayment(
        host: otherHost('ana'),
        paymentId: 'p1',
        to: c.me,
        amount: 100,
        method: 'shieldedZec',
        reference: _txid,
      ),
    ]);

    await t.pumpWidget(app(c, ActivityScreen(billId: id)));
    await t.pumpAndSettle();
    // Shown once, on the card that asks whether it arrived (§14.2), and not
    // again in the list: the list names a reference for the payer only.
    expect(find.textContaining('tx ${_txid.substring(0, 14)}'), findsOneWidget);
  });
}
