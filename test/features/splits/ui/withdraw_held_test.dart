// Withdrawing a payment record this wallet's own history shows went through,
// or may still go through.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'support/closing.dart';

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
  await closeForSettling(c, id);
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

  testWidgets('only this device\'s own record is withdrawn, never one the '
      'payee wrote in its name', (t) async {
    final c = controllerFor(FakeWallet(), const {});
    late String id;
    await t.runAsync(() async {
      id = await owingBen(c);
      await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
      // Ben writes a record of the same debt naming this device as payer,
      // which §10.8 lets a payee do. It is Ben's word, not this device's.
      final written = entries.recordPayment(
        host: otherHost('ben'),
        paymentId: 'b1',
        to: c.me,
        amount: 1000,
        method: 'cash',
      );
      final payment = Map<String, dynamic>.from(
        written['payment'] as Map<String, dynamic>,
      )..addAll({'from': c.me, 'to': 'ben'});
      final entry = Map<String, dynamic>.from(written)
        ..['payment'] = payment
        ..remove('id');
      entry['id'] = protocol.deriveEntryId(entry);
      await c.accept(id, [entry]);
    });
    final before = c.bills.firstWhere((b) => b.id == id);
    expect(before.bill.payments, hasLength(2));

    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(home: SettleScreen(billId: id)),
      ),
    );
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_withdraw_ben')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_withdraw_confirm')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pumpAndSettle();

    expect(c.lastError, isNull);
    final after = c.bills.firstWhere((b) => b.id == id);
    expect(
      [for (final p in after.bill.payments) after.paymentAuthors[p.id]],
      ['ben'],
    );
  });
}
