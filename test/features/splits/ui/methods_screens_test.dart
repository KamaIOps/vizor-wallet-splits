/// Declaring how you are paid, and settling the two lanes a request cannot
/// carry.
///
/// A bill settles in one of three ways (§9.2). Two of them — a swap off this
/// chain and cash — can never be outputs of a ZIP 321 request, so §8.5 leaves
/// them out and reports them. What these assert is that the reported ones are
/// reachable rather than a dead end, and that what gets written says what
/// actually happened.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as splitz;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

/// A bill this device owes somebody on.
Future<String> billOwing(SplitsController c, {required String other}) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  // The other person joins and covers a cost split between the two.
  final theirHost = otherHost(other);
  await c.accept(id, [
    entries.joinBill(host: theirHost, name: other, payTo: 'u1$other'),
    entries.addExpense(
      host: theirHost,
      expenseId: 'x1',
      paidBy: other,
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': [c.me, other]..sort(),
      },
    ),
  ]);
  await c.setRate(
    billId: id,
    currency: 'USD',
    minorUnitsPerZec: 100000,
    source: 'fixed',
  );
  return id;
}

void main() {
  group('declaring how you are paid', () {
    testWidgets('a bill opens on the choice this device already made', (
      t,
    ) async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet);
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      // A later instant than the join that opened the bill, as on a device:
      // at one instant §10.2 falls back to the ids, and which record wins
      // would then depend on what the entries hash to.
      wallet.tick();
      await c.setPayouts(
        billId: id,
        payouts: const [splitz.Payout(type: 'cash')],
      );

      await t.pumpWidget(app(c, PayoutScreen(billId: id)));
      await t.pumpAndSettle();

      final tile = t.widget<RadioListTile<PayoutChoice>>(
        find.byKey(const Key('splits_payout_cash')),
      );
      expect(tile.value, PayoutChoice.cash);
      // Opening on a default would overwrite what was already declared the
      // moment somebody saved.
      final group = t.widget<RadioGroup<PayoutChoice>>(
        find.byType(RadioGroup<PayoutChoice>),
      );
      expect(group.groupValue, PayoutChoice.cash);
    });

    testWidgets('a swap must name the asset AND the chain', (t) async {
      // One symbol exists on many chains; the wrong chain delivers the right
      // token where the recipient cannot reach it.
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

      await t.pumpWidget(app(c, PayoutScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_swap')));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('splits_payout_asset')), 'USDC');
      // The form scrolls; the button is below the fold on a short surface.
      await t.ensureVisible(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();

      expect(find.text('Name the chain'), findsOneWidget);
      // Nothing was written: a half-named payout is not a payout.
      final view = c.bills.firstWhere((b) => b.id == id);
      expect(view.bill.participant(c.me)!.payouts, isEmpty);
    });

    testWidgets('a saved swap payout reaches the bill in order', (t) async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet);
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      wallet.tick();

      await t.pumpWidget(app(c, PayoutScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_swap')));
      await t.pumpAndSettle();
      // With no swap provider the chains cannot be listed, so the asset and
      // chain are typed.
      for (final (key, text) in [
        ('splits_payout_asset', 'USDC'),
        ('splits_payout_chain', 'base'),
        ('splits_payout_address', '0xme'),
      ]) {
        await t.dragUntilVisible(
          find.byKey(Key(key)),
          find.byType(ListView),
          const Offset(0, -100),
        );
        await t.enterText(find.byKey(Key(key)), text);
      }
      // The form scrolls; the button is below the fold on a short surface.
      await t.ensureVisible(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();

      final me = c.bills.firstWhere((b) => b.id == id).bill.participant(c.me)!;
      expect(me.payouts.single.type, 'swap');
      expect(me.payouts.single.asset, 'USDC');
      expect(me.payouts.single.chain, 'base');
      expect(me.payouts.single.address, '0xme');
      // §8.5: a swap payout is not an address this request can carry.
      expect(me.payableAddress, isNull);
    });
  });

  testWidgets('a first swap changed to another asset is kept after the new '
      'one (§9.1)', (t) async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    wallet.tick();
    await c.setPayouts(
      billId: id,
      payouts: const [
        splitz.Payout(
          type: 'swap',
          asset: 'DAI',
          chain: 'arb',
          address: '0xold',
        ),
      ],
    );
    wallet.tick();

    await t.pumpWidget(app(c, PayoutScreen(billId: id)));
    await t.pumpAndSettle();
    for (final (key, text) in [
      ('splits_payout_asset', 'USDT'),
      ('splits_payout_chain', 'base'),
      ('splits_payout_address', '0xnew'),
    ]) {
      await t.dragUntilVisible(
        find.byKey(Key(key)),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await t.enterText(find.byKey(Key(key)), text);
    }
    await t.ensureVisible(find.byKey(const Key('splits_payout_save')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_payout_save')));
    await t.pumpAndSettle();

    final me = c.bills.firstWhere((b) => b.id == id).bill.participant(c.me)!;
    // A new swap replaces only those of its own asset: DAI stays, after it.
    expect(
      [for (final p in me.payouts) '${p.asset} ${p.chain} ${p.address}'],
      ['USDT base 0xnew', 'DAI arb 0xold'],
    );
  });

  testWidgets('a debt is not paid another way while a send is unresolved '
      '(§14.8)', (t) async {
    const pending = WalletSendOutcome(
      phase: WalletSendPhase.pendingBroadcast,
      statusMessage: 'created, not broadcast',
    );
    Future<(SplitsController, String)> owingBenAndCashCai(
      WalletSendOutcome outcome,
    ) async {
      final c = controllerFor(FakeWallet(outcome: outcome));
      final id = await billOwing(c, other: 'ben');
      final cai = otherHost('cai');
      await c.accept(id, [
        entries.joinBill(
          host: cai,
          name: 'cai',
          payouts: [
            <String, dynamic>{'type': 'cash'},
          ],
        ),
        entries.addExpense(
          host: cai,
          expenseId: 'y1',
          paidBy: 'cai',
          amount: 2000,
          split: <String, dynamic>{
            'type': 'equal',
            'among': [c.me, 'cai']..sort(),
          },
        ),
      ]);
      return (c, id);
    }

    // The control: nothing in flight, so Cai's cash row opens the record.
    final (free, freeId) =
        await t.runAsync(() => owingBenAndCashCai(pending))
            as (SplitsController, String);
    await t.pumpWidget(app(free, SettleScreen(billId: freeId)));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.byKey(const Key('splits_settle_unpayable_cai')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.byKey(const Key('splits_settle_unpayable_cai')));
    await t.pumpAndSettle();
    expect(find.byType(RecordPaymentScreen), findsOneWidget);

    // Ben's ZEC send left unresolved: Cai's row opens nothing.
    final (held, heldId) =
        await t.runAsync(() async {
              final (c, id) = await owingBenAndCashCai(pending);
              final sent = await c.settle(id, (await c.obligation(id))!);
              expect(sent!.result.name, 'pending');
              return (c, id);
            })
            as (SplitsController, String);
    expect(await t.runAsync(() => held.pendingSend(heldId)), isNotNull);
    // A fresh tree: the control's navigator still holds the record screen.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app(held, SettleScreen(billId: heldId)));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.byKey(const Key('splits_settle_unpayable_cai')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.byKey(const Key('splits_settle_unpayable_cai')));
    await t.pumpAndSettle();
    expect(find.byType(RecordPaymentScreen), findsNothing);
  });

  group('the lanes a request cannot carry', () {
    testWidgets('a cash recipient is offered a way to settle, not a dead end', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await billOwing(c, other: 'ben');
      // Ben wants cash, so §8.5 reports him instead of paying him.
      await c.accept(id, [
        entries.joinBill(
          host: otherHost('ben'),
          name: 'ben',
          payouts: [
            <String, dynamic>{'type': 'cash'},
          ],
        ),
      ]);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.textContaining('You → '), findsOneWidget);
      expect(find.byKey(const Key('splits_settle_apart_ben')), findsOneWidget);
    });

    testWidgets('somebody with no address at all is offered nothing', (
      t,
    ) async {
      // A dead end until they publish something — offering a record would
      // invite a claim about money that has nowhere to go.
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      final host = otherHost('eve');
      await c.accept(id, [
        entries.joinBill(host: host, name: 'eve'),
        entries.addExpense(
          host: host,
          expenseId: 'x1',
          paidBy: 'eve',
          amount: 2000,
          split: <String, dynamic>{
            'type': 'equal',
            'among': [c.me, 'eve']..sort(),
          },
        ),
      ]);
      await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.textContaining('No Zcash address yet'), findsOneWidget);
      expect(find.byKey(const Key('splits_settle_apart_eve')), findsNothing);
    });
  });

  group('recording what happened', () {
    testWidgets('cash is recorded as cash, and says nothing is verified', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await billOwing(c, other: 'ben');

      await t.pumpWidget(
        app(
          c,
          RecordPaymentScreen(billId: id, to: 'ben', suggestedMinorUnits: 1000),
        ),
      );
      await t.pumpAndSettle();

      // The figure owed is already there, so the common case is one tap.
      expect(find.text('10.00'), findsOneWidget);
      expect(
        find.textContaining('Counts once they confirm it.'),
        findsOneWidget,
      );

      // The form outgrows a 600-pixel surface once the swap field shows.
      await t.drag(find.byType(ListView), const Offset(0, -300));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_record_save')));
      await t.pumpAndSettle();

      final bill = c.bills.firstWhere((b) => b.id == id).bill;
      final payment = bill.payments.single;
      expect(payment.method, 'cash');
      expect(payment.amount, 1000);
      expect(payment.to, 'ben');
      // No transaction exists, so nothing pretends one does.
      expect(payment.reference, isNull);
      // A record is a claim: §10.5 gives the settlement to the payee.
      expect(bill.confirmedPayments, isNot(contains(payment.id)));
    });

    testWidgets('a swap will not record without its reference', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billOwing(c, other: 'ben');

      await t.pumpWidget(
        app(
          c,
          RecordPaymentScreen(billId: id, to: 'ben', suggestedMinorUnits: 1000),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_record_swap')));
      await t.pumpAndSettle();
      // The form outgrows a 600-pixel surface once the swap field shows.
      await t.drag(find.byType(ListView), const Offset(0, -300));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_record_save')));
      await t.pumpAndSettle();

      expect(find.textContaining('nobody can look up'), findsOneWidget);
      expect(c.bills.firstWhere((b) => b.id == id).bill.payments, isEmpty);
    });

    testWidgets('a swap records its reference, and warns it is half visible', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await billOwing(c, other: 'ben');

      await t.pumpWidget(
        app(
          c,
          RecordPaymentScreen(billId: id, to: 'ben', suggestedMinorUnits: 1000),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_record_swap')));
      await t.pumpAndSettle();

      expect(find.textContaining('not a Zcash txid'), findsOneWidget);
      expect(find.textContaining('confirm it arrived'), findsOneWidget);

      await t.enterText(
        find.byKey(const Key('splits_record_reference')),
        'near-intent-7f3a',
      );
      // The form outgrows a 600-pixel surface once the swap field shows.
      await t.drag(find.byType(ListView), const Offset(0, -300));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_record_save')));
      await t.pumpAndSettle();

      final payment = c.bills
          .firstWhere((b) => b.id == id)
          .bill
          .payments
          .single;
      expect(payment.method, 'swap');
      expect(payment.reference, 'near-intent-7f3a');
      expect(payment.id, '${c.me}:near-intent-7f3a');
    });

    testWidgets('a payment of nothing is refused', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billOwing(c, other: 'ben');

      await t.pumpWidget(app(c, RecordPaymentScreen(billId: id, to: 'ben')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('splits_record_amount')), '0');
      // The form outgrows a 600-pixel surface once the swap field shows.
      await t.drag(find.byType(ListView), const Offset(0, -300));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_record_save')));
      await t.pumpAndSettle();

      expect(find.text('More than nothing'), findsOneWidget);
      expect(c.bills.firstWhere((b) => b.id == id).bill.payments, isEmpty);
    });
  });

  group('the history, and the tap that settles a debt', () {
    testWidgets('a recorded payment reads as still owed until confirmed', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await billOwing(c, other: 'ben');
      await c.recordCash(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1000,
        note: 'at the table',
      );

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();

      // A record is a claim (§10.5). Saying "paid" without this tells a payer
      // a debt is discharged that the payee never agreed was paid.
      expect(find.textContaining('not confirmed yet'), findsOneWidget);
    });

    testWidgets('the payer is NOT offered the confirmation', (t) async {
      // Confirming your own payment settles a debt by asserting twice that
      // you paid it.
      final c = controllerFor(FakeWallet());
      final id = await billOwing(c, other: 'ben');
      await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.text('It arrived'), findsNothing);
      expect(find.textContaining('says they paid you'), findsNothing);
    });

    testWidgets('the payee confirms, and the debt stops being outstanding', (
      t,
    ) async {
      // Ben's device: Ana owes him, and says she paid in cash.
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
        entries.joinBill(host: ana, name: 'ana', payTo: 'u1ana'),
        entries.recordPayment(
          host: ana,
          paymentId: 'p1',
          to: c.me,
          amount: 1000,
          method: 'cash',
        ),
      ]);
      await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.textContaining('says they paid you'), findsOneWidget);
      expect(
        find.textContaining('nothing verifies this but you'),
        findsOneWidget,
      );

      // One tap asks; it does not settle.
      await t.tap(find.byKey(const Key('splits_confirm_arrived_ana:p1')));
      await t.pumpAndSettle();
      expect(
        c.bills.firstWhere((b) => b.id == id).bill.confirmedPayments,
        isEmpty,
      );
      await t.tap(find.byKey(const Key('splits_confirm_sure_ana:p1')));
      await t.pumpAndSettle();

      final bill = c.bills.firstWhere((b) => b.id == id).bill;
      expect(bill.confirmedPayments, contains('ana:p1'));
      // The offer is gone, because the debt is.
      expect(
        find.byKey(const Key('splits_confirm_arrived_ana:p1')),
        findsNothing,
      );

      // And it can be taken back by the one who said it.
      final undo = find.byKey(
        Key(
          'splits_unconfirm_${c.bills.single.activity.firstWhere((e) => e.kind == BillEventKind.paymentConfirmed).entryId}',
        ),
      );
      expect(undo, findsOneWidget);
      await t.tap(undo);
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Take it back').last);
      await t.pumpAndSettle();
      expect(
        c.bills.firstWhere((b) => b.id == id).bill.confirmedPayments,
        isEmpty,
      );
      expect(
        find.byKey(const Key('splits_confirm_arrived_ana:p1')),
        findsOneWidget,
      );
    });

    testWidgets('a payee is shown the ZEC, the rate and the transaction, and '
        'can say it did not arrive', (t) async {
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
      const txid = 'ab01';
      await c.accept(id, [
        entries.joinBill(host: ana, name: 'ana', payTo: 'u1ana'),
        entries.recordPayment(
          host: ana,
          paymentId: '$txid:${c.me}',
          to: c.me,
          amount: 1000,
          reference: txid,
          zatoshi: 1000000,
          paidAtRate: const <String, dynamic>{
            'currency': 'USD',
            'minorUnitsPerZec': 100000,
            'at': '2026-10-28T19:30:00.000Z',
          },
        ),
      ]);
      final paymentId = 'ana:$txid:${c.me}';

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.byKey(Key('splits_confirm_zec_$paymentId')), findsOneWidget);
      expect(find.text('0.01 ZEC'), findsOneWidget);
      expect(find.byKey(Key('splits_confirm_rate_$paymentId')), findsOneWidget);
      expect(find.text('transaction $txid'), findsWidgets);
      expect(find.textContaining('not a Zcash transaction'), findsNothing);

      await t.tap(find.byKey(Key('splits_confirm_refuse_$paymentId')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('splits_confirm_refuse_sure_$paymentId')));
      await t.pumpAndSettle();
      final bill = c.bills.firstWhere((b) => b.id == id).bill;
      expect(bill.payments, isEmpty, reason: 'the payee withdrew the record');
    });

    testWidgets('a swap confirmation warns the asset is the thing to check', (
      t,
    ) async {
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
        entries.joinBill(host: ana, name: 'ana', payTo: 'u1ana'),
        entries.recordPayment(
          host: ana,
          paymentId: 'near-intent-7f3a',
          to: c.me,
          amount: 1000,
          method: 'swap',
          reference: 'near-intent-7f3a',
        ),
      ]);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();

      // The ZEC leg leaving is not the asset arriving, and only Ben can say
      // the latter.
      expect(
        find.textContaining('check the asset actually arrived'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('splits_confirm_ana:near-intent-7f3a')),
          matching: find.textContaining('not a Zcash transaction'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the confirm card shows every §14.2 payee fact', (t) async {
      final c = controllerFor(FakeWallet(id: 'ben', payTo: 'u1ben'));
      await c.load();
      final ana = otherHost('ana');
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      await c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 4000,
        among: ['ana', c.me]..sort(),
      );
      const txid =
          '1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809';
      await c.accept(id, [
        entries.joinBill(host: ana, name: 'ana', payTo: 'u1ana'),
        entries.recordPayment(
          host: ana,
          paymentId: '$txid:${c.me}',
          to: c.me,
          amount: 1000,
          reference: txid,
          zatoshi: 714286,
          paidAtRate: const <String, dynamic>{
            'currency': 'USD',
            'minorUnitsPerZec': 140000,
            'at': '2026-10-28T19:30:00.000Z',
          },
        ),
        // A swap record: its reference is the provider's, and it carries no
        // ZEC figure or rate.
        entries.recordPayment(
          host: ana,
          paymentId: 'near-intent-7f3a',
          to: c.me,
          amount: 1000,
          method: 'swap',
          reference: 'near-intent-7f3a',
        ),
      ]);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();

      final bill = c.bills.firstWhere((b) => b.id == id).bill;
      for (final payment in bill.payments) {
        final card = find.byKey(Key('splits_confirm_${payment.id}'));
        final shown = [
          for (final w in t.widgetList<Text>(
            find.descendant(of: card, matching: find.byType(Text)),
          ))
            w.data ?? w.textSpan?.toPlainText() ?? '',
          for (final w in t.widgetList<SelectableText>(
            find.descendant(of: card, matching: find.byType(SelectableText)),
          ))
            w.data ?? '',
        ];
        expect(
          checkPayeeReview(
            payment: payment,
            visibleText: shown,
            absentWords: 'not recorded',
          ),
          isEmpty,
          reason: '${payment.method} card shows: $shown',
        );
      }
    });

    testWidgets('an entry the fold refused is shown with its reason', (
      t,
    ) async {
      // An entry that vanished silently is indistinguishable from one that
      // was never sent.
      final c = controllerFor(FakeWallet());
      final id = await billOwing(c, other: 'ben');
      await c.accept(id, [
        entries.recordPayment(
          host: otherHost('ben'),
          paymentId: 'bad',
          to: 'ben',
          amount: 100,
          method: 'cash',
        ),
      ]);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.textContaining('not applied'), findsOneWidget);
    });
  });
}
