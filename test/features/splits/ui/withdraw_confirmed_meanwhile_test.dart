// The settle screen withdraws only this device's unconfirmed records,
// including when the payee's confirmation lands while the dialog is open.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'settle_send_test.dart' show owingBen, controllerFor;
import 'support/fake_wallet.dart';

Future<(SplitsController, FakeWallet, String, String)> _cashToBen() async {
  final wallet = FakeWallet();
  final c = controllerFor(wallet, InMemoryBillStorage());
  final id = await owingBen(c);
  await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
  final payment = c.bills.single.bill.payments.single.id;
  return (c, wallet, id, payment);
}

Future<void> _bensConfirmation(
  SplitsController c,
  FakeWallet wallet,
  String id,
  String payment,
) async {
  wallet.tick();
  await c.accept(id, [
    entries.confirmPayment(
      host: otherHost('ben'),
      paymentId: payment,
      method: 'recipientConfirmed',
      record: c.bills.single.paymentDigests[payment]!,
    ),
  ]);
}

Future<void> _open(WidgetTester t, SplitsController c, String id) async {
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(home: SettleScreen(billId: id)),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('control: confirmed before the screen opens -> no Withdraw', (
    t,
  ) async {
    final (c, wallet, id, payment) = await _cashToBen();
    await _bensConfirmation(c, wallet, id, payment);
    await _open(t, c, id);
    final shown = find.byKey(const Key('splits_settle_withdraw_ben'));
    expect(shown, findsNothing);
  });

  testWidgets('control: unconfirmed, withdrawn -> owed again (intended)', (
    t,
  ) async {
    final (c, wallet, id, payment) = await _cashToBen();
    await _open(t, c, id);
    await t.tap(find.byKey(const Key('splits_settle_withdraw_ben')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_withdraw_confirm')));
    await t.pumpAndSettle();
    expect(c.bills.single.bill.payments, isEmpty);
  });

  testWidgets('confirmation lands while the dialog is open', (t) async {
    final (c, wallet, id, payment) = await _cashToBen();
    await _open(t, c, id);
    await t.tap(find.byKey(const Key('splits_settle_withdraw_ben')));
    await t.pumpAndSettle();
    // Ben's confirmation syncs in while the payer reads the dialog.
    await t.runAsync(() => _bensConfirmation(c, wallet, id, payment));
    await t.pumpAndSettle();
    expect(
      c.bills.single.bill.confirmedPayments,
      contains(payment),
      reason: 'the confirmation landed while the dialog was open',
    );
    await t.tap(find.byKey(const Key('splits_settle_withdraw_confirm')));
    await t.pumpAndSettle();
    final bill = c.bills.single.bill;
    expect(
      bill.payments.map((p) => p.id),
      contains(payment),
      reason: 'a payment Ben confirmed was withdrawn',
    );
    expect(c.lastError, contains('confirmed as arrived'));
  });
}
