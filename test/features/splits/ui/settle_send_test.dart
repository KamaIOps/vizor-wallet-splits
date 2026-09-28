/// Sending what this device owes: what the payer accepts, and what a send
/// that did not resolve leaves behind.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet, BillStorage storage) =>
    SplitsController(
      wallet: wallet,
      store: BillStore(storage),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
    );

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

/// A priced bill where this device owes Ben 10.00 USD at 1000.00 USD a ZEC.
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

/// The same bill with Ben — the one being paid — joined from his own device
/// and writing the rate. §10.1 takes a rate only from a bound participant.
Future<(String, SignedPeer)> owingBenWhoPrices(SplitsController c) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = await SignedPeer.named('ben');
  await c.accept(id, [
    await ben.join(id, name: 'ben', payTo: 'u1benpayable0000000001'),
    await ben.sign(
      entries.addExpense(
        host: ben.host,
        expenseId: 'x1',
        paidBy: ben.id,
        amount: 2000,
        split: <String, dynamic>{
          'type': 'equal',
          'among': [ben.id, c.me]..sort(),
        },
      ),
      id,
    ),
    await ben.sign(
      entries.setRate(
        host: ben.host,
        currency: 'USD',
        minorUnitsPerZec: 100000,
      ),
      id,
    ),
  ]);
  return (id, ben);
}

const _pending = WalletSendOutcome(
  phase: WalletSendPhase.pendingBroadcast,
  statusMessage: 'created, not broadcast',
);

const _txid =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// Two expenses at the §2.2 cap, both owed by [me]: 184,467,440,736 minor
/// units, past the 92,233,720,368 §7.1 can price, while no single entry is
/// refused.
List<Map<String, dynamic>> unpriceable(entries.BillHost ben, String me) => [
  for (var i = 0; i < 2; i++)
    entries.addExpense(
      host: ben,
      expenseId: 'x$i',
      paidBy: 'ben',
      amount: 92233720368,
      split: <String, dynamic>{
        'type': 'equal',
        'among': [me],
      },
    ),
];

void main() {
  group('a send that did not resolve', () {
    test('blocks another send, across a restart', () async {
      final storage = InMemoryBillStorage();
      final wallet = FakeWallet(outcome: _pending);
      final c = controllerFor(wallet, storage);
      final id = await owingBen(c);

      final owed = (await c.obligation(id))!;
      final first = await c.settle(id, owed);
      expect(first!.result.name, 'pending');
      expect(wallet.sender.sent, hasLength(1));

      // The same device, started again over the same storage.
      final again = controllerFor(wallet, storage);
      await again.load();
      expect(await again.pendingSend(id), isNotNull);
      expect((await again.pendingSend(id))!.carried, {'ben': 1000});

      await again.settle(id, (await again.obligation(id))!);
      expect(
        wallet.sender.sent,
        hasLength(1),
        reason: 'a second send would pay the debt twice if the first lands',
      );
      expect(again.lastError, contains('has not been resolved'));
    });

    test('found on chain, it is recorded as a sent one would be', () async {
      final wallet = FakeWallet(outcome: _pending);
      final c = controllerFor(wallet, InMemoryBillStorage());
      final id = await owingBen(c);
      await c.settle(id, (await c.obligation(id))!);

      await c.resolveSend(id, landed: true, txid: 'not a txid');
      expect(c.lastError, contains('not a transaction id'));
      expect(await c.pendingSend(id), isNotNull);

      await c.resolveSend(id, landed: true, txid: _txid.toUpperCase());
      expect(c.lastError, isNull);
      expect(await c.pendingSend(id), isNull);
      final bill = c.bills.single.bill;
      expect(bill.payments.single.id, '$_txid:ben');
      expect(bill.payments.single.amount, 1000);
      expect(bill.payments.single.reference, _txid);

      // Held back as awaiting now, not asked for again.
      final owed = (await c.obligation(id))!;
      expect(owed.uri, isNull);
      expect(owed.awaiting.single.to, 'ben');
    });

    test('the transaction a pending send built is kept, and records it '
        'with the ZEC and the rate', () async {
      final wallet = FakeWallet(
        outcome: const WalletSendOutcome(
          phase: WalletSendPhase.pendingBroadcast,
          statusMessage: 'created, not broadcast',
          txid: _txid,
        ),
      );
      final c = controllerFor(wallet, InMemoryBillStorage());
      final id = await owingBen(c);
      final settled = await c.settle(id, (await c.obligation(id))!);
      expect(settled!.txid, _txid);
      expect((await c.pendingSend(id))!.txid, _txid);

      // Resolved with no id typed: the one the wallet built is used.
      await c.resolveSend(id, landed: true);
      expect(c.lastError, isNull);
      final payment = c.bills.single.bill.payments.single;
      expect(payment.id, '$_txid:ben');
      // 10.00 USD at 1000.00 USD a ZEC is 0.01 ZEC.
      expect(payment.zatoshi, 1000000);
      expect(payment.paidAtRate!.minorUnitsPerZec, 100000);
    });

    test('said not to have gone through, the debt can be sent again', () async {
      final wallet = FakeWallet(outcome: _pending);
      final c = controllerFor(wallet, InMemoryBillStorage());
      final id = await owingBen(c);
      await c.settle(id, (await c.obligation(id))!);

      await c.resolveSend(id);
      expect(await c.pendingSend(id), isNull);
      expect(c.bills.single.bill.payments, isEmpty);
      await c.settle(id, (await c.obligation(id))!);
      expect(wallet.sender.sent, hasLength(2));
    });

    testWidgets('the screen shows it and holds Send back', (t) async {
      final wallet = FakeWallet(outcome: _pending);
      final c = controllerFor(wallet, InMemoryBillStorage());
      final id = await owingBen(c);
      await c.settle(id, (await c.obligation(id))!);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_pending_send')), findsOneWidget);
      final send = t.widget<FilledButton>(
        find.byKey(const Key('splits_settle_send')),
      );
      expect(send.onPressed, isNull);
    });
  });

  test('a send refuses figures the bill no longer agrees with', () async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet, InMemoryBillStorage());
    final id = await owingBen(c);
    final shown = (await c.obligation(id))!;

    // The bill is repriced after the payer read it.
    wallet.tick();
    await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 10000);

    await c.settle(id, shown);
    expect(wallet.sender.sent, isEmpty);
    expect(c.lastError, contains('changed since'));
  });

  group('before anything is sent', () {
    testWidgets('the payer sees the ZEC, the address and the rate', (t) async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet, InMemoryBillStorage());
      final id = await owingBen(c);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_settle_send')));
      await t.pumpAndSettle();

      // 10.00 USD at 1000.00 USD per ZEC.
      expect(find.text('0.01 ZEC'), findsOneWidget);
      expect(find.text('u1benpayable0000000001'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byKey(const Key('splits_settle_rate')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('splits_review_setter_paid')), findsNothing);

      // Cancelled, nothing goes out.
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(wallet.sender.sent, isEmpty);

      await t.tap(find.byKey(const Key('splits_settle_send')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_review_send')));
      await t.pumpAndSettle();
      expect(wallet.sender.sent, hasLength(1));
    });

    testWidgets('a rate set by the payee is called out', (t) async {
      final c = controllerFor(FakeWallet(), InMemoryBillStorage());
      final (id, ben) = await owingBenWhoPrices(c);
      expect(c.bills.single.rateSetBy, ben.id);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_settle_send')));
      await t.pumpAndSettle();

      expect(
        find.byKey(const Key('splits_review_setter_paid')),
        findsOneWidget,
      );
    });
  });

  testWidgets('a payment no shared expense explains is called out', (t) async {
    // Ben writes a "refund" paid by the payer and owed by himself. §4 admits
    // a negative total, so it stands, and the payer now owes him 30.00 that
    // no debt of theirs accounts for.
    final c = controllerFor(FakeWallet(), InMemoryBillStorage());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final ben = otherHost('ben');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'ben', payTo: 'u1benpayable0000000001'),
      entries.addExpense(
        host: ben,
        expenseId: 'x1',
        paidBy: c.me,
        amount: -3000,
        split: const <String, dynamic>{
          'type': 'equal',
          'among': ['ben'],
        },
      ),
    ]);
    await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();

    expect(
      find.byKey(const Key('splits_settle_unexplained_ben')),
      findsOneWidget,
    );
    expect(
      find.textContaining('explains ${formatAmount(3000, 'USD')} of this'),
      findsOneWidget,
    );
    expect(find.textContaining('entered by ben'), findsOneWidget);
  });

  testWidgets('a refund this person entered is stated, not flagged', (t) async {
    // The same refund, entered by the payer. It is their own word, so it is
    // explained to them without the warning.
    final c = controllerFor(FakeWallet(), InMemoryBillStorage());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final ben = otherHost('ben');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'ben', payTo: 'u1benpayable0000000001'),
    ]);
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: -3000,
      among: const ['ben'],
    );
    await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();

    final line = find.byKey(const Key('splits_settle_unexplained_ben'));
    expect(line, findsOneWidget);
    expect(
      find.textContaining(
        'A refund you entered accounts for ${formatAmount(3000, 'USD')}',
      ),
      findsOneWidget,
    );
    expect(t.widget<Text>(line).style, isNull);
  });

  testWidgets('a debt no request can price is said, not spun on', (t) async {
    // 184,467,440,736 minor units owed: past the 92,233,720,368 §7 can turn
    // into zatoshi without overflowing, so pricing it refuses.
    final c = controllerFor(FakeWallet(), InMemoryBillStorage());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final ben = otherHost('ben');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'ben', payTo: 'u1benpayable0000000001'),
      ...unpriceable(ben, c.me),
    ]);
    await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();

    // §8.5: reported as a recipient this request cannot carry, not refused.
    expect(
      find.byKey(const Key('splits_settle_unpayable_ben')),
      findsOneWidget,
    );
    expect(
      find.textContaining('more than one payment request'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a record of a payment that never left can be withdrawn', (
    t,
  ) async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet, InMemoryBillStorage());
    final id = await owingBen(c);
    wallet.tick();
    await c.settle(id, (await c.obligation(id))!);
    expect((await c.obligation(id))!.uri, isNull, reason: 'awaiting Ben');

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    wallet.tick();
    await t.tap(find.byKey(const Key('splits_settle_withdraw_ben')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_withdraw_confirm')));
    await t.pumpAndSettle();

    expect(c.lastError, isNull);
    final owed = (await c.obligation(id))!;
    expect(owed.awaiting, isEmpty);
    expect(owed.settlements.single.amount, 1000);
    expect(find.byKey(const Key('splits_settle_send')), findsOneWidget);
  });

  group('what the review holds the request against', () {
    Future<void> openReview(
      WidgetTester t,
      SplitsController c,
      String id,
    ) async {
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_settle_send')));
      await t.pumpAndSettle();
    }

    testWidgets('a rate far from the live price is called out, whoever set it', (
      t,
    ) async {
      // The bill says 1000.00 USD a ZEC; the market says 2000.00. Half the
      // price is twice the ZEC, and a second name on the bill hides who set it.
      final c = SplitsController(
        wallet: FakeWallet(),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        prices: const _Price(200000),
      );
      final id = await owingBen(c);
      await openReview(t, c, id);
      expect(find.byKey(const Key('splits_review_rate_off')), findsOneWidget);
      expect(find.textContaining('50% below'), findsOneWidget);
    });

    testWidgets('a rate at the live price is not', (t) async {
      final c = SplitsController(
        wallet: FakeWallet(),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        prices: const _Price(101000),
      );
      final id = await owingBen(c);
      await openReview(t, c, id);
      expect(find.byKey(const Key('splits_review_rate_off')), findsNothing);
      expect(
        find.byKey(const Key('splits_review_rate_unchecked')),
        findsNothing,
      );
    });

    testWidgets('no price to check the rate against is said', (t) async {
      // No feed prices this currency, so nothing can say the rate is wrong —
      // which is not the same as it being right.
      final c = controllerFor(FakeWallet(), InMemoryBillStorage());
      final id = await owingBen(c);
      await openReview(t, c, id);
      expect(
        find.byKey(const Key('splits_review_rate_unchecked')),
        findsOneWidget,
      );
    });

    testWidgets('an address nobody bound is called out; a bound one is not', (
      t,
    ) async {
      // Ben's join in owingBen is unsigned, so anyone could have written it.
      final c = controllerFor(FakeWallet(), InMemoryBillStorage());
      final id = await owingBen(c);
      await openReview(t, c, id);
      expect(
        find.byKey(const Key('splits_review_unbound_ben')),
        findsOneWidget,
      );

      // Cai joins from his own device, signed with his own key.
      final cai = await SignedPeer.named('cai');
      final c2 = controllerFor(FakeWallet(), InMemoryBillStorage());
      await c2.load();
      final id2 = (await c2.createBill(name: 'Taxi', currency: 'USD'))!;
      await c2.accept(id2, [
        await cai.join(id2, name: 'cai', payTo: 'u1caipayable00000000001'),
        await cai.sign(
          entries.addExpense(
            host: cai.host,
            expenseId: 'x1',
            paidBy: cai.id,
            amount: 2000,
            split: <String, dynamic>{
              'type': 'equal',
              'among': [cai.id, c2.me]..sort(),
            },
          ),
          id2,
        ),
      ]);
      await c2.setRate(billId: id2, currency: 'USD', minorUnitsPerZec: 100000);
      expect(c2.bills.single.identities.bound, contains(cai.id));
      await t.pumpWidget(const SizedBox());
      await openReview(t, c2, id2);
      expect(find.byKey(const Key('splits_review_send')), findsOneWidget);
      expect(find.byKey(Key('splits_review_unbound_${cai.id}')), findsNothing);
    });
  });

  testWidgets('a record on a debt the payment reroutes can be withdrawn', (
    t,
  ) async {
    // The payer owes Carol, Carol owes Ben, so the plan pays Ben and covers
    // Carol. A cash record to Carol holds Ben's payment back; the line names
    // Carol, who the money went to, and its button reaches that record.
    final wallet = FakeWallet();
    final c = controllerFor(wallet, InMemoryBillStorage());
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    final ben = otherHost('ben');
    final carol = otherHost('carol');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben00000000000000001'),
      entries.joinBill(
        host: carol,
        name: 'Carol',
        payTo: 'u1carol000000000000001',
      ),
      entries.addExpense(
        host: carol,
        expenseId: 'x1',
        paidBy: 'carol',
        amount: 1000,
        split: <String, dynamic>{
          'type': 'equal',
          'among': [c.me],
        },
      ),
      entries.addExpense(
        host: ben,
        expenseId: 'x2',
        paidBy: 'ben',
        amount: 1000,
        split: const <String, dynamic>{
          'type': 'equal',
          'among': ['carol'],
        },
      ),
    ]);
    await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
    wallet.tick();
    await c.recordCash(billId: id, to: 'carol', amountMinorUnits: 1000);
    wallet.tick();
    // A second record holding the same debt, to Ben, which did arrive.
    await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1);
    expect((await c.obligation(id))!.awaiting.single.to, 'ben');
    expect((await c.obligation(id))!.awaiting.single.paidTo, ['ben', 'carol']);

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    // Named by who the money went to, one control each.
    expect(find.text('Waiting on Ben, Carol'), findsOneWidget);
    expect(find.byKey(const Key('splits_settle_withdraw_ben')), findsOneWidget);
    wallet.tick();
    await t.tap(find.byKey(const Key('splits_settle_withdraw_carol')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_withdraw_confirm')));
    await t.pumpAndSettle();

    // Carol's record is withdrawn; Ben's, which arrived, stands.
    final payments = c.bills.single.bill.payments;
    expect(payments.map((p) => p.to), ['ben']);
    final after = (await c.obligation(id))!;
    expect(after.awaiting.single.paidTo, ['ben']);
  });

  testWidgets('a stored send that no longer reads says what to do, and does '
      'not offer a record it cannot write', (t) async {
    final storage = InMemoryBillStorage();
    final c = controllerFor(FakeWallet(), storage);
    final id = await owingBen(c);
    await storage.write('payintent/$id', 'not json');

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_pending_unreadable')), findsOneWidget);
    expect(find.byKey(const Key('splits_pending_txid')), findsNothing);
    final record = t.widget<FilledButton>(
      find.byKey(const Key('splits_pending_record')),
    );
    expect(record.onPressed, isNull);
  });

  testWidgets('a send out is shown even when the debts cannot be priced', (
    t,
  ) async {
    final storage = InMemoryBillStorage();
    final c = controllerFor(FakeWallet(), storage);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final ben = otherHost('ben');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'ben', payTo: 'u1benpayable0000000001'),
      ...unpriceable(ben, c.me),
    ]);
    await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
    await storage.write('payintent/$id', 'not json');

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    expect(
      find.byKey(const Key('splits_settle_unpayable_ben')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('splits_pending_send')), findsOneWidget);
  });
}

class _Price implements ZecPrices {
  const _Price(this.minorUnits);

  final int minorUnits;

  @override
  Future<int?> minorUnitsPerZec(String currency) async => minorUnits;
}
