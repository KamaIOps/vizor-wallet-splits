// §14.10 through the wallet: the ZEC payees and one swap deposit in one
// transaction, recorded both ways, and recorded both ways after a restart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps, controllerFor;

/// This device owes Ben 10.00, paid in ZEC, and Cai 5.00, paid in USDC on
/// Base. Closed for settling unless [closed] is false.
Future<(SplitsController, FakeWallet, String)> _bill({
  bool closed = true,
  bool cash = false,
  WalletSendOutcome outcome = const WalletSendOutcome(
    phase: WalletSendPhase.succeeded,
    txid: 'tx-combined',
  ),
  FakeSwaps? swaps,
}) async {
  final wallet = FakeWallet(outcome: outcome);
  final c = controllerFor(wallet, swaps: swaps ?? FakeSwaps());
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final ben = otherHost('ben');
  final cai = otherHost('cai');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benpayable0000000001'),
    entries.joinBill(
      host: cai,
      name: 'Cai',
      payouts: [
        <String, dynamic>{
          'type': 'swap',
          'asset': 'USDC',
          'chain': 'base',
          'address': '0xcai',
        },
      ],
    ),
    entries.addExpense(
      host: ben,
      expenseId: 'hotel',
      paidBy: 'ben',
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['ben', c.me]..sort(),
      },
    ),
    entries.addExpense(
      host: cai,
      expenseId: 'cab',
      paidBy: 'cai',
      amount: 1000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['cai', c.me]..sort(),
      },
    ),
  ]);
  if (cash) {
    final dee = otherHost('dee');
    await c.accept(id, [
      entries.joinBill(
        host: dee,
        name: 'Dee',
        payouts: [
          <String, dynamic>{'type': 'cash'},
        ],
      ),
      entries.addExpense(
        host: dee,
        expenseId: 'taxi',
        paidBy: 'dee',
        amount: 600,
        split: <String, dynamic>{
          'type': 'equal',
          'among': ['dee', c.me]..sort(),
        },
      ),
    ]);
  }
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  if (closed) await c.closeForSettling(id);
  return (c, wallet, id);
}

Future<SwapQuote> _quote(SplitsController c, String id) async =>
    (await c.quoteSwap(billId: id, to: 'cai', amountMinorUnits: 500))!;

/// A provider whose deposits need a memo, which a ZIP 321 request with other
/// outputs cannot carry for one of them (§14.10).
class _MemoSwaps extends FakeSwaps {
  @override
  Future<SwapQuote> quote({
    required TradableAsset asset,
    required int amountInZatoshi,
    required String recipient,
    required String refundTo,
  }) async {
    final q = await super.quote(
      asset: asset,
      amountInZatoshi: amountInZatoshi,
      recipient: recipient,
      refundTo: refundTo,
    );
    return SwapQuote(
      depositAddress: q.depositAddress,
      amountInZatoshi: q.amountInZatoshi,
      amountOut: q.amountOut,
      minAmountOut: q.minAmountOut,
      asset: q.asset,
      deadline: q.deadline,
      reference: q.reference,
      recipient: q.recipient,
      depositMemo: 'needed',
    );
  }
}

Future<void> _openSettle(WidgetTester t, SplitsController c, String id) async {
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(home: SettleScreen(billId: id)),
    ),
  );
  await t.pumpAndSettle();
}

String _button(WidgetTester t) => t
    .widget<Text>(
      find.descendant(
        of: find.byKey(const Key('splits_settle_send')),
        matching: find.byType(Text),
      ),
    )
    .data!;

Future<void> _openReview(WidgetTester t, SplitsController c, String id) async {
  await _openSettle(t, c, id);
  await t.tap(find.byKey(const Key('splits_settle_send')));
  await t.pumpAndSettle();
}

Future<void> _send(WidgetTester t) async {
  await t.ensureVisible(find.byKey(const Key('splits_review_send')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('splits_review_send')));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the review shows Ben in ZEC and Cai through the swap, and one '
      'Send pays both in one transaction', (t) async {
    final (c, wallet, id) = await _bill();
    await _openSettle(t, c, id);
    expect(_button(t), contains('by swap'));
    expect(
      find.byKey(const Key('splits_settle_withheld')),
      findsNothing,
      reason: 'the swap is in this send, so nothing is left owed',
    );
    await _openReview(t, c, id);

    expect(find.byKey(const Key('splits_review_swap')), findsOneWidget);
    expect(find.byKey(const Key('splits_review_withheld')), findsNothing);
    expect(find.byKey(const Key('splits_review_swap_floor')), findsOneWidget);
    expect(find.text('u1benpayable0000000001'), findsOneWidget);
    // 10.00 + 5.00 USD at 1000.00 USD a ZEC, before the fee.
    expect(find.text('0.015 ZEC'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('splits_review_unpaid')),
        matching: find.textContaining('Cai'),
      ),
      findsNothing,
      reason: 'Cai is paid by this send',
    );

    await _send(t);
    expect(wallet.sender.sent, hasLength(1));
    expect(wallet.sender.sent.single, contains('u1benpayable0000000001'));
    expect(wallet.sender.sent.single, contains('u1provider'));
    final to = c.bills.single.bill.payments.map((p) => p.to).toSet();
    expect(to, {'ben', 'cai'});
  });

  testWidgets('with Dee paid in cash too, the one Send pays Ben and Cai, the '
      'review says Dee is not in it, and Dee is recorded as cash', (t) async {
    final (c, wallet, id) = await _bill(cash: true);
    final owed = (await c.obligation(id))!;
    expect(owed.unpayable.map((u) => u.id).toSet(), {'cai', 'dee'});
    await _openSettle(t, c, id);
    // Ben 10.00 + Cai 5.00 in this send; Dee's 3.00 in cash is left.
    final leftLine = t.widget<Text>(
      find.byKey(const Key('splits_settle_withheld')),
    );
    expect(leftLine.data, contains('15.00'));
    expect(leftLine.data, contains('3.00'));
    await _openReview(t, c, id);
    final reviewLine = t.widget<Text>(
      find.byKey(const Key('splits_review_withheld')),
    );
    expect(reviewLine.data, contains('15.00'));
    expect(reviewLine.data, contains('leaves 3.00 USD owed'));

    expect(find.byKey(const Key('splits_review_swap')), findsOneWidget);
    expect(
      find.byKey(const Key('splits_review_unpayable_dee')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('splits_review_unpayable_cai')), findsNothing);

    await _send(t);
    expect(wallet.sender.sent, hasLength(1));
    expect(wallet.sender.sent.single, contains('u1provider'));
    expect(c.bills.single.bill.payments.map((p) => p.to).toSet(), {
      'ben',
      'cai',
    });

    await c.recordCash(billId: id, to: 'dee', amountMinorUnits: 300);
    expect(c.lastError, isNull);
    final dee = c.bills.single.bill.payments.singleWhere((p) => p.to == 'dee');
    expect(dee.method, 'cash');
    // Nothing left to pay; each payment waits on its payee's word (§10.5).
    final left = (await c.obligation(id))!;
    expect(left.carriedTo, isEmpty);
    expect(left.unpayable, isEmpty);
    expect(left.awaiting, hasLength(3));
  });

  testWidgets('a deposit that needs a memo is left to its own send, and the '
      'review says Cai is not in this one', (t) async {
    final (c, wallet, id) = await _bill(swaps: _MemoSwaps());
    await _openReview(t, c, id);

    expect(find.byKey(const Key('splits_review_swap')), findsNothing);
    expect(find.byKey(const Key('splits_review_unpaid')), findsOneWidget);

    await _send(t);
    expect(wallet.sender.sent, hasLength(1));
    expect(wallet.sender.sent.single, isNot(contains('u1provider')));
    expect(c.bills.single.bill.payments.map((p) => p.to), ['ben']);
  });

  test(
    'one send pays Ben in ZEC and Cai through the swap, and records both',
    () async {
      final (c, wallet, id) = await _bill();
      final owed = (await c.obligation(id))!;
      expect(owed.carriedTo, {'ben': 1000});
      expect(owed.unpayable.single.id, 'cai');
      final quote = await _quote(c, id);

      final out = await c.settleWithSwap(
        billId: id,
        owed: owed,
        to: 'cai',
        amountMinorUnits: 500,
        quote: quote,
      );
      expect(c.lastError, isNull);
      expect(out!.phase, WalletSendPhase.succeeded);
      expect(wallet.sender.sent, hasLength(1), reason: 'one transaction');
      expect(wallet.sender.sent.single, contains('u1benpayable0000000001'));
      expect(wallet.sender.sent.single, contains(quote.depositAddress));

      final payments = c.bills.single.bill.payments;
      final zec = payments.singleWhere((p) => p.to == 'ben');
      final swap = payments.singleWhere((p) => p.to == 'cai');
      expect(zec.method, 'shieldedZec');
      expect(zec.reference, 'tx-combined');
      expect(swap.method, 'swap');
      expect(swap.reference, quote.paymentReference);
      expect(await c.pendingSend(id), isNull, reason: 'both halves recorded');
    },
  );

  test('an open bill sends nothing', () async {
    final (c, wallet, id) = await _bill(closed: false);
    final owed = (await c.obligation(id))!;
    await c.settleWithSwap(
      billId: id,
      owed: owed,
      to: 'cai',
      amountMinorUnits: 500,
      quote: await _quote(c, id),
    );
    expect(c.lastError, contains('Close the bill for settling'));
    expect(wallet.sender.sent, isEmpty);
  });

  test('an expired quote sends nothing, not even the ZEC', () async {
    final (c, wallet, id) = await _bill(
      swaps: FakeSwaps(deadline: '2020-01-01T00:00:00.000Z'),
    );
    final owed = (await c.obligation(id))!;
    await c.settleWithSwap(
      billId: id,
      owed: owed,
      to: 'cai',
      amountMinorUnits: 500,
      quote: await _quote(c, id),
    );
    expect(c.lastError, isNotNull);
    expect(wallet.sender.sent, isEmpty);
    expect(c.bills.single.bill.payments, isEmpty);
  });

  test('left unresolved, it is recorded both ways once it is said to have '
      'landed', () async {
    final (c, wallet, id) = await _bill(
      outcome: const WalletSendOutcome(
        phase: WalletSendPhase.pendingBroadcast,
        statusMessage: 'created, not broadcast',
      ),
    );
    final owed = (await c.obligation(id))!;
    final quote = await _quote(c, id);
    await c.settleWithSwap(
      billId: id,
      owed: owed,
      to: 'cai',
      amountMinorUnits: 500,
      quote: quote,
    );
    expect(c.bills.single.bill.payments, isEmpty);
    final note = await c.pendingSend(id);
    expect(note, isNotNull);
    expect(note!.swap!.to, 'cai');

    await c.resolveSend(id, landed: true, txid: 'f' * 64);
    expect(c.lastError, isNull);
    final payments = c.bills.single.bill.payments;
    expect(payments.map((p) => p.to).toSet(), {'ben', 'cai'});
    expect(payments.singleWhere((p) => p.to == 'ben').reference, 'f' * 64);
    expect(await c.pendingSend(id), isNull);
  });
}
