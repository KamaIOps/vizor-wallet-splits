// §14.4: a debt held because other payers' unconfirmed payments already cover
// what the plan still owes the payee. Nothing of this payer's is waiting, so
// nothing is offered to take back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps, app, controllerFor;

/// Ben paid a 30.00 dinner shared by Ben, Cai and this device; Cai says they
/// paid Ben 20.00, which Ben has not confirmed.
Future<(SplitsController, String)> _bill(WidgetTester t) async {
  final c = controllerFor(FakeWallet(), swaps: FakeSwaps());
  late String id;
  await t.runAsync(() async {
    await c.load();
    id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    final ben = otherHost('ben');
    final cai = otherHost('cai');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benpayable0000000001'),
      entries.joinBill(host: cai, name: 'Cai', payTo: 'u1caipayable0000000001'),
      entries.addExpense(
        host: ben,
        expenseId: 'dinner',
        paidBy: 'ben',
        amount: 3000,
        split: <String, dynamic>{
          'type': 'equal',
          'among': ['ben', 'cai', c.me]..sort(),
        },
      ),
      entries.recordPayment(
        host: cai,
        paymentId: 'cash-1',
        to: 'ben',
        amount: 2000,
        method: 'cash',
      ),
    ]);
    await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
    await c.closeForSettling(id);
  });
  return (c, id);
}

void main() {
  testWidgets('the settle screen says others paid, and offers nothing to '
      'take back', (t) async {
    final (c, id) = await _bill(t);
    late entries.PayerObligation owed;
    await t.runAsync(() async => owed = (await c.obligation(id))!);
    final held = owed.awaiting.singleWhere((a) => a.to == 'ben');
    expect(held.othersPaid, 2000);
    expect(held.paid, 0);

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    expect(
      find.byKey(const Key('splits_settle_others_paid_ben')),
      findsOneWidget,
    );
    expect(find.textContaining('Others sent Ben 20.00 USD'), findsOneWidget);
    expect(find.byKey(const Key('splits_settle_withdraw_ben')), findsNothing);
  });
}
