/// What a bill's header says this device owes, and what it has already sent
/// that the payee has not confirmed (§14.4: two quantities).
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

Widget _app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(key: UniqueKey(), home: home),
);

/// Ben paid 20.00 USD for himself and this device, which owes him 10.00.
Future<(SplitsController, FakeWallet, String)> _owesBen() async {
  final wallet = FakeWallet();
  final c = SplitsController(
    wallet: wallet,
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  );
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
    entries.addExpense(
      host: ben,
      expenseId: 'x1',
      paidBy: 'ben',
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': [c.me, 'ben']..sort(),
      },
    ),
  ]);
  wallet.tick();
  return (c, wallet, id);
}

String? _text(WidgetTester t, Key key) {
  final found = find.descendant(
    of: find.byKey(key),
    matching: find.byType(Text),
    matchRoot: true,
  );
  return found.evaluate().isEmpty ? null : t.widget<Text>(found).data;
}

void main() {
  testWidgets('a part sent and not confirmed is said beside what is owed', (
    t,
  ) async {
    final (c, _, id) = await _owesBen();
    await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 400);
    expect(c.lastError, isNull);

    await t.pumpWidget(_app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    // Still owed: §10.5 moves nothing until Ben confirms.
    expect(_text(t, const Key('splits_bill_headline')), 'You owe 10.00 USD');
    expect(
      _text(t, const Key('splits_bill_sent')),
      '4.00 USD sent, not yet confirmed',
    );

    // The list's row is the name and the figure; what is on its way is said
    // on the bill and in the list's totals.
    await t.pumpWidget(_app(c, const BillsScreen()));
    await t.pumpAndSettle();
    expect(find.byKey(Key('splits_bill_row_sent_$id')), findsNothing);
  });

  testWidgets('the whole debt sent is said as sent, and still owed', (t) async {
    final (c, _, id) = await _owesBen();
    await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);

    await t.pumpWidget(_app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(_text(t, const Key('splits_bill_headline')), 'You owe 10.00 USD');
    expect(
      _text(t, const Key('splits_bill_sent')),
      '10.00 USD sent, not yet confirmed',
    );
  });

  testWidgets('nothing sent, or all of it confirmed, says nothing more', (
    t,
  ) async {
    final (c, wallet, id) = await _owesBen();
    await t.pumpWidget(_app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_bill_sent')), findsNothing);

    await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
    final payment = c.bills.single.bill.payments.single.id;
    wallet.tick();
    await c.accept(id, [
      entries.confirmPayment(
        host: otherHost('ben'),
        paymentId: payment,
        method: 'recipientConfirmed',
        record: c.bills.single.paymentDigests[payment]!,
      ),
    ]);
    expect(c.bills.single.bill.confirmedPayments, contains(payment));
    await t.pumpWidget(_app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(_text(t, const Key('splits_bill_headline')), 'All settled');
    expect(find.byKey(const Key('splits_bill_sent')), findsNothing);
  });

  testWidgets('owing nothing on a bill others still owe on is not "settled"', (
    t,
  ) async {
    final wallet = FakeWallet();
    final c = SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
    );
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    final ben = otherHost('ben');
    final cara = otherHost('cara');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
      entries.joinBill(host: cara, name: 'Cara', payTo: 'u1cara'),
      entries.addExpense(
        host: ben,
        expenseId: 'x1',
        paidBy: 'ben',
        amount: 2000,
        split: <String, dynamic>{
          'type': 'equal',
          'among': ['ben', 'cara'],
        },
      ),
    ]);
    expect(c.lastError, isNull);
    await t.pumpWidget(_app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(_text(t, const Key('splits_bill_headline')), 'You owe nothing');
  });

  testWidgets('a bill with no expenses says so', (t) async {
    final c = SplitsController(
      wallet: FakeWallet(),
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
    );
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    await t.pumpWidget(_app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(_text(t, const Key('splits_bill_headline')), 'No expenses yet');
  });
}
