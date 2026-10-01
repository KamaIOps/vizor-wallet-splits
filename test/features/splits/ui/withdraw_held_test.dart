// Withdrawing a payment record this wallet's own history shows went through,
// or may still go through.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

const _txid =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

SplitsController controllerFor(
  FakeWallet wallet,
  Map<String, HeldTransaction>? held,
) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  held: () async => held ?? (throw StateError('history unreadable')),
);

Future<String> owingBen(SplitsController c) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'ben', payTo: 'u1benpayable0000000001'),
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
  return id;
}

FakeWallet _paid() => FakeWallet(
  outcome: const WalletSendOutcome(
    phase: WalletSendPhase.succeeded,
    txid: _txid,
  ),
);

/// A bill where this device paid Ben by a shielded send and recorded it.
Future<(SplitsController, String, String)> _recorded(
  FakeWallet wallet,
  Map<String, HeldTransaction>? held,
) async {
  final c = controllerFor(wallet, held);
  final id = await owingBen(c);
  wallet.tick();
  await c.settle(id, (await c.obligation(id))!);
  final view = c.bills.firstWhere((b) => b.id == id);
  final payment = view.bill.payments.single;
  expect(payment.reference, _txid);
  return (c, id, view.paymentEntries[payment.id]!);
}

void main() {
  testWidgets('"It did not reach" is refused when the send went through', (
    t,
  ) async {
    final wallet = _paid();
    final (c, id, _) = await _recorded(wallet, {_txid: HeldTransaction.mined});
    expect((await c.obligation(id))!.uri, isNull);

    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(home: SettleScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();
    wallet.tick();
    await t.tap(find.byKey(const Key('splits_settle_withdraw_ben')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_withdraw_confirm')));
    await t.pumpAndSettle();

    expect(c.lastError, contains('went through'));
    expect(find.textContaining('went through'), findsOneWidget);
    final again = (await c.obligation(id))!;
    expect(again.uri, isNull, reason: 'the debt is not offered again');
    expect(wallet.sender.sent, hasLength(1));
  });

  test('a send the wallet still holds is refused', () async {
    final (c, id, entry) = await _recorded(_paid(), {
      _txid: HeldTransaction.waiting,
    });
    await c.withdraw(billId: id, entryId: entry);
    expect(c.lastError, contains('may send it'));
    expect((await c.obligation(id))!.uri, isNull);
  });

  for (final (name, held) in [
    ('expired', <String, HeldTransaction>{_txid: HeldTransaction.expired}),
    ('not in this wallet', <String, HeldTransaction>{}),
    ('history unreadable', null),
  ]) {
    test('a send $name is withdrawn and owed again', () async {
      final (c, id, entry) = await _recorded(_paid(), held);
      await c.withdraw(billId: id, entryId: entry);
      expect(c.lastError, isNull);
      expect((await c.obligation(id))!.uri, isNotNull);
    });
  }

  test('a cash record is withdrawn whatever the history says', () async {
    final c = controllerFor(_paid(), {_txid: HeldTransaction.mined});
    final id = await owingBen(c);
    await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
    expect(c.lastError, isNull);
    final view = c.bills.firstWhere((b) => b.id == id);
    final entry = view.paymentEntries[view.bill.payments.single.id]!;
    await c.withdraw(billId: id, entryId: entry);
    expect(c.lastError, isNull);
    expect(c.bills.firstWhere((b) => b.id == id).bill.payments, isEmpty);
  });
}
