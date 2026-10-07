/// A payer settles a debt by another payout its recipient declared (§14.8),
/// chosen on the settle screen: a payer with no ZEC pays a payee who also
/// takes cash in cash.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/closing.dart';
import 'support/fake_wallet.dart';

const _zec = {'type': 'zec', 'address': 'u1benpayable0000000001'};
const _cash = {'type': 'cash'};

SplitsController _controller() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

Widget _app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

/// This device owes Ben 10.00 USD, and Ben declared [payouts], most
/// preferred first.
Future<String> _owingBen(
  SplitsController c,
  List<Map<String, dynamic>> payouts,
) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'ben', payouts: payouts),
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
  await closeForSettling(c, id);
  return id;
}

void main() {
  testWidgets('a payee who also takes cash can be paid in cash', (t) async {
    final c = _controller();
    final id = await _owingBen(c, [_zec, _cash]);
    await t.pumpWidget(_app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();

    // Zcash is Ben's first choice, so the debt starts in the request.
    expect(find.byKey(const Key('splits_settle_pay_ben')), findsOneWidget);
    await t.tap(find.byKey(const Key('splits_settle_other_way_ben')));
    await t.pumpAndSettle();
    expect(find.text('Pay ben another way'), findsOneWidget);
    expect(find.byKey(const Key('splits_other_way_ben_1')), findsOneWidget);

    await t.tap(find.byKey(const Key('splits_other_way_ben_1')));
    await t.pumpAndSettle();
    // Cash has nothing to send: the record opens for the amount owed.
    expect(find.byType(RecordPaymentScreen), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();

    // Back on the screen, Ben is paid apart, in cash, and the payer can go
    // back to his first choice.
    expect(find.byKey(const Key('splits_settle_pay_ben')), findsNothing);
    expect(find.byKey(const Key('splits_settle_apart_ben')), findsOneWidget);
    expect(find.text('Their 2nd choice · Cash'), findsOneWidget);
    await t.tap(find.byKey(const Key('splits_settle_first_choice_ben')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_settle_pay_ben')), findsOneWidget);
    expect(find.byKey(const Key('splits_settle_apart_ben')), findsNothing);
    // Nothing rewrote Ben's order.
    expect(c.bills.single.bill.participant('ben')!.payouts.map((p) => p.type), [
      'zec',
      'cash',
    ]);
  });

  testWidgets('a payee with one way to be paid offers no other', (t) async {
    final c = _controller();
    final id = await _owingBen(c, [_zec]);
    await t.pumpWidget(_app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_settle_pay_ben')), findsOneWidget);
    expect(find.byKey(const Key('splits_settle_other_way_ben')), findsNothing);
  });

  testWidgets('a payee who takes cash first can be paid in ZEC instead', (
    t,
  ) async {
    final c = _controller();
    final id = await _owingBen(c, [_cash, _zec]);
    await t.pumpWidget(_app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();

    // Cash first: paid apart, nothing in the request.
    expect(find.byKey(const Key('splits_settle_apart_ben')), findsOneWidget);
    expect(find.byKey(const Key('splits_settle_send')), findsNothing);
    await t.tap(find.byKey(const Key('splits_settle_other_way_ben')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_other_way_ben_1')));
    await t.pumpAndSettle();

    // A Zcash pick goes into the one request.
    expect(find.byKey(const Key('splits_settle_pay_ben')), findsOneWidget);
    expect(find.byKey(const Key('splits_settle_send')), findsOneWidget);
    expect(
      find.byKey(const Key('splits_settle_first_choice_ben')),
      findsOneWidget,
    );
  });
}
