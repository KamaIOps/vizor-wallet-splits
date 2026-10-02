/// Two taps on a submit in one frame write once and leave one screen.
///
/// The second tap reaches the handler the first frame built, before any
/// rebuild has disabled the button: only a flag the handler sets before its
/// first await stops it.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController _ctl(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
);

/// [screen] pushed over a page that stays beneath it, so a second pop shows.
Future<void> _over(WidgetTester t, SplitsController c, Widget screen) async {
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('beneath'),
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => screen)),
              child: const Text('beneath'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const Key('beneath')));
  await t.pumpAndSettle();
}

Future<void> _twice(WidgetTester t, Key key) async {
  final button = find.byKey(key);
  await t.ensureVisible(button);
  await t.pumpAndSettle();
  await t.tap(button);
  await t.tap(button);
  await t.pumpAndSettle();
}

/// A priced bill on which this device owes Ben 10.00 USD.
Future<(SplitsController, FakeWallet, String)> _owesBen({
  WalletSendOutcome? outcome,
}) async {
  final wallet = outcome == null ? FakeWallet() : FakeWallet(outcome: outcome);
  final c = _ctl(wallet);
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benpayable0000000001'),
    entries.addExpense(
      host: ben,
      expenseId: 'x1',
      paidBy: 'ben',
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['ben', c.me]..sort(),
      },
    ),
  ]);
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  wallet.tick();
  return (c, wallet, id);
}

int _entries(SplitsController c) => c.bills.single.entryCount;

void main() {
  testWidgets('add expense', (t) async {
    final (c, _, id) = await _owesBen();
    final before = c.bills.single.bill.expenses.length;
    await _over(t, c, AddExpenseScreen(billId: id));
    await t.enterText(find.byKey(const Key('splits_amount')), '12');
    await _twice(t, const Key('splits_expense_save'));
    expect(c.bills.single.bill.expenses.length, before + 1);
    expect(find.byKey(const Key('beneath')), findsOneWidget);
  });

  testWidgets('record a payment', (t) async {
    final (c, _, id) = await _owesBen();
    await _over(
      t,
      c,
      RecordPaymentScreen(billId: id, to: 'ben', suggestedMinorUnits: 500),
    );
    await _twice(t, const Key('splits_record_save'));
    expect(c.bills.single.bill.payments, hasLength(1));
    expect(find.byKey(const Key('beneath')), findsOneWidget);
  });

  testWidgets('how you get paid', (t) async {
    final (c, _, id) = await _owesBen();
    final before = _entries(c);
    await _over(t, c, PayoutScreen(billId: id));
    await _twice(t, const Key('splits_payout_save'));
    expect(_entries(c), before + 1);
    expect(find.byKey(const Key('beneath')), findsOneWidget);
  });

  testWidgets('how somebody added by name gets paid', (t) async {
    final (c, _, id) = await _owesBen();
    await c.addPerson(billId: id, id: 'cal', name: 'Cal');
    final before = _entries(c);
    await _over(t, c, PayoutForScreen(billId: id, id: 'cal', name: 'Cal'));
    await t.enterText(find.byKey(const Key('splits_address_field')), 'u1cal');
    await _twice(t, const Key('splits_address_save'));
    expect(_entries(c), before + 1);
    expect(find.byKey(const Key('beneath')), findsOneWidget);
  });

  testWidgets('price the bill', (t) async {
    final (c, _, id) = await _owesBen();
    final before = _entries(c);
    await _over(t, c, PriceBillScreen(billId: id));
    await t.enterText(find.byType(TextFormField).first, '1200');
    await _twice(t, const Key('splits_price_apply'));
    expect(_entries(c), before + 1);
    expect(find.byKey(const Key('beneath')), findsOneWidget);
  });

  testWidgets('add a person, OK tapped twice', (t) async {
    final (c, _, id) = await _owesBen();
    final before = c.bills.single.bill.participants.length;
    await _over(t, c, PeopleScreen(billId: id));
    await t.tap(find.byKey(const Key('splits_people_add')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('splits_people_name')), 'Cal');
    await _twice(t, const Key('splits_people_name_ok'));
    expect(c.bills.single.bill.participants.length, before + 1);
    expect(c.lastError, isNull);
    // Back on the list the name was added from.
    expect(find.byType(PeopleScreen), findsOneWidget);
  });

  testWidgets('settle: Send in the review tapped twice', (t) async {
    final (c, wallet, id) = await _owesBen();
    await _over(t, c, SettleScreen(billId: id));
    await t.tap(find.byKey(const Key('splits_settle_send')));
    await t.pumpAndSettle();
    await _twice(t, const Key('splits_review_send'));
    expect(wallet.sender.sent, hasLength(1));
    expect(find.byType(SettleScreen), findsOneWidget);
  });

  testWidgets('settle: "It went through" tapped twice', (t) async {
    final (c, _, id) = await _owesBen(
      outcome: const WalletSendOutcome(
        phase: WalletSendPhase.pendingBroadcast,
        statusMessage: 'created, not broadcast',
      ),
    );
    await _over(t, c, SettleScreen(billId: id));
    await t.tap(find.byKey(const Key('splits_settle_send')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_review_send')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_pending_send')), findsOneWidget);
    await t.enterText(
      find.byKey(const Key('splits_pending_txid')),
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
    final before = _entries(c);
    await _twice(t, const Key('splits_pending_record'));
    expect(_entries(c), before + 1);
    expect(c.bills.single.bill.payments, hasLength(1));
    expect(c.bills.single.setAside, isEmpty);
  });

  testWidgets('how somebody gets paid, unchanged, Save tapped twice', (
    t,
  ) async {
    final (c, wallet, id) = await _owesBen();
    await c.addPerson(billId: id, id: 'cal', name: 'Cal');
    wallet.tick();
    await c.setAddressFor(billId: id, id: 'cal', address: 'u1cal');
    expect(c.bills.single.bill.participant('cal')!.payTo, 'u1cal');
    final before = _entries(c);
    await _over(t, c, PayoutForScreen(billId: id, id: 'cal', name: 'Cal'));
    await _twice(t, const Key('splits_address_save'));
    expect(_entries(c), before);
    expect(find.byKey(const Key('beneath')), findsOneWidget);
  });

  testWidgets('a refused tap leaves the next one free to write', (t) async {
    final (c, _, id) = await _owesBen();
    final before = c.bills.single.bill.expenses.length;
    await _over(t, c, AddExpenseScreen(billId: id));
    await t.tap(find.byKey(const Key('splits_expense_save')));
    await t.pumpAndSettle();
    expect(find.text('Enter an amount like 12.50'), findsOneWidget);
    await t.enterText(find.byKey(const Key('splits_amount')), '12');
    await t.tap(find.byKey(const Key('splits_expense_save')));
    await t.pumpAndSettle();
    expect(c.bills.single.bill.expenses.length, before + 1);

    await _over(
      t,
      c,
      RecordPaymentScreen(billId: id, to: 'ben', suggestedMinorUnits: 500),
    );
    await t.enterText(find.byKey(const Key('splits_record_amount')), '0');
    await t.tap(find.byKey(const Key('splits_record_save')));
    await t.pumpAndSettle();
    expect(c.bills.single.bill.payments, isEmpty);
    await t.enterText(find.byKey(const Key('splits_record_amount')), '5');
    await t.tap(find.byKey(const Key('splits_record_save')));
    await t.pumpAndSettle();
    expect(c.bills.single.bill.payments, hasLength(1));
  });
}
