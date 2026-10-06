// A bill everybody is square on shows how it was settled, then that it is.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/closing.dart';
import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show app, controllerFor;

/// This device paid a 20.00 dinner shared with Ana, so Ana owes it 10.00,
/// and Ana says she paid in cash.
Future<(SplitsController, String)> _bill({
  String method = 'cash',
  String? reference,
}) async {
  final c = controllerFor(FakeWallet(id: 'ben', payTo: 'u1ben'));
  await c.load();
  final ana = otherHost('ana');
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  await c.addExpense(
    billId: id,
    paidBy: c.me,
    amountMinorUnits: 2000,
    among: ['ana', c.me]..sort(),
  );
  await c.accept(id, [
    entries.joinBill(host: ana, name: 'Ana', payTo: 'u1ana'),
    entries.recordPayment(
      host: ana,
      paymentId: 'p1',
      to: c.me,
      amount: 1000,
      method: method,
      reference: reference,
      zatoshi: method == 'shieldedZec' ? 1000000 : null,
    ),
  ]);
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await closeForSettling(c, id);
  return (c, id);
}

void main() {
  testWidgets('waiting on a confirmation, it is not yet settled', (t) async {
    final (c, id) = await _bill();
    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.text('Everything is settled up.'), findsNothing);
    expect(find.byKey(const Key('splits_settle_history_ana:p1')), findsNothing);
  });

  testWidgets('once confirmed, the payment is listed and then it is settled', (
    t,
  ) async {
    final (c, id) = await _bill();
    await c.confirmPayment(
      billId: id,
      paymentId: 'ana:p1',
      method: 'recipientConfirmed',
    );
    expect(c.lastError, isNull);
    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();

    expect(find.text('How this bill was settled'), findsOneWidget);
    final row = find.byKey(const Key('splits_settle_history_ana:p1'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.textContaining('Ana →')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('cash · confirmed'),
      ),
      findsOneWidget,
    );
    expect(find.text('Everything is settled up.'), findsOneWidget);
    // The history comes before the line that says it is done.
    expect(
      t.getTopLeft(row).dy,
      lessThan(t.getTopLeft(find.text('Everything is settled up.')).dy),
    );
  });

  testWidgets('a settled ZEC payment opens to its whole transaction id, and '
      'the explorer is given that id', (t) async {
    final txid =
        'a3093a55012830639f57282b43e25e47726b2ec679c7c285b0bea2950a37a3f8';
    final (c, id) = await _bill(method: 'shieldedZec', reference: txid);
    await c.confirmPayment(
      billId: id,
      paymentId: 'ana:p1',
      method: 'recipientConfirmed',
    );
    final opened = <String>[];
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        openTransaction: (tx) async {
          opened.add(tx);
          return true;
        },
        child: MaterialApp(home: SettleScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_history_ana:p1')));
    await t.pumpAndSettle();
    expect(
      find.byKey(const Key('splits_settled_reference_ana:p1')),
      findsOneWidget,
    );
    expect(find.text(txid), findsOneWidget, reason: 'whole, not shortened');
    await t.tap(find.byKey(const Key('splits_settled_explorer_ana:p1')));
    await t.pumpAndSettle();
    expect(opened, [txid]);
  });

  testWidgets('a cash payment says it has no transaction', (t) async {
    final (c, id) = await _bill();
    await c.confirmPayment(
      billId: id,
      paymentId: 'ana:p1',
      method: 'recipientConfirmed',
    );
    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_history_ana:p1')));
    await t.pumpAndSettle();
    expect(find.text('none — paid in cash'), findsOneWidget);
    expect(
      find.byKey(const Key('splits_settled_explorer_ana:p1')),
      findsNothing,
    );
  });
}
