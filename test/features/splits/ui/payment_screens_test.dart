/// The payment screens: which payout is passed over, what a failed or
/// expiring swap offers, what a payout screen saves untouched, how a lane is
/// labelled, what reference a payee is shown, and one review per tap.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' show Payout, Participant;
import 'package:zcash_wallet/src/features/splits/ui/screens/arrivals_screen.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'support/closing.dart';

/// A provider that delivers USDC on base, quoting a deadline [deadline]
/// builds from the moment of quoting.
class _Swaps implements SwapProvider {
  _Swaps({String Function()? deadline})
    : deadline = deadline ?? (() => '2099-01-01T00:00:00.000Z');

  final String Function() deadline;
  int quotes = 0;

  @override
  Future<List<TradableAsset>> tradableAssets() async => const [
    nativeZec,
    TradableAsset(
      assetId: 'base-usdc',
      symbol: 'USDC',
      chain: 'base',
      decimals: 6,
    ),
  ];

  @override
  Future<SwapQuote> quote({
    required TradableAsset asset,
    required int amountInZatoshi,
    required String recipient,
    required String refundTo,
  }) async {
    quotes++;
    return SwapQuote(
      depositAddress: 'u1provider',
      amountInZatoshi: amountInZatoshi,
      amountOut: '10000000',
      minAmountOut: '9900000',
      asset: asset,
      deadline: deadline(),
      reference: 'near-intent-1',
      recipient: recipient,
    );
  }

  @override
  Future<SwapStatus> statusOf(SwapQuote quote) async =>
      const SwapStatus(state: SwapState.awaitingDeposit);
}

/// A price feed that answers when the test says so.
class _Held implements ZecPrices {
  final answer = Completer<int?>();
  int asked = 0;

  @override
  Future<int?> minorUnitsPerZec(String currency) {
    asked++;
    return answer.future;
  }
}

SplitsController controllerFor(
  FakeWallet wallet, {
  ReadsAddress? reads,
  SwapProvider? swaps,
  ZecPrices? prices,
}) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  swaps: swaps ?? _Swaps(),
  prices: prices ?? const NoZecPrices(),
  readsAddress: reads ?? (_) async => true,
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

/// This device owes ben 10.00 USD at 1000.00 USD a ZEC; ben, added by name
/// and unbound, declared [payouts] and [payTo].
Future<String> owingBen(
  SplitsController c,
  List<Map<String, dynamic>>? payouts, {
  String? payTo,
}) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben', payTo: payTo);
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'ben', payTo: payTo, payouts: payouts),
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

/// As [owingBen], with ben joined from his own device, so his record is his
/// alone to write (§10.7).
Future<(String, SignedPeer)> owingBoundBen(
  SplitsController c,
  List<Map<String, dynamic>> payouts,
) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = await SignedPeer.named('ben');
  await c.accept(id, [
    await ben.sign(
      entries.joinBill(
        host: ben.host,
        name: 'ben',
        identityKey: ben.key,
        payouts: payouts,
      ),
      id,
    ),
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
  ]);
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await closeForSettling(c, id);
  return (id, ben);
}

/// An address the wallet's reader refuses, standing for one on another
/// network.
const _otherNetwork = 'utest1wrongnetwork000000';

const _insufficient =
    'Propose failed: Insufficient balance (have 1000, need 1010000 including '
    'fee)';

/// Addresses of each kind §8.6 names, from the protocol's
/// `vectors/address.json`.
const _p2pkh = 't1Hsc1LR8yKnbbe3twRp88p6vFfC5t7DLbs';
const _p2sh = 't3JZcvsuaXE6ygokL4XUiZSTrQBUoPYFnXJ';
const _tex = 'tex1s2rt77ggv6q989lr49rkgzmh5slsksa9khdgte';
const _sapling =
    'zs1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpq6d8g';

/// Receivers [2, 3]: Sapling and Orchard.
const _uaShielded =
    'u1ay3aawlldjrmxqnjf5medr5ma6p3acnet464ht8lmwplq5cd3ugytcmlf96rrmtgwldc75'
    'x94qn4n8pgen36y8tywlq6yjk7lkf3fa8wzjrav8z2xpxqnrnmjxh8tmz6jhfh425t7f3vy6'
    'p4pd3zmqayq49efl2c4xydc0gszg660q9p';

/// Receivers [0, 2]: P2PKH and Sapling. Paid at its Sapling receiver.
const _uaWithTransparent =
    'u1l8xunezsvhq8fgzfl7404m450nwnd76zshscn6nfys7vyz2ywyh4cc5daaq0c7q2su5lqf'
    'h23sp7fkf3kt27ve5948mzpfdvckzaect2jtte308mkwlycj2u0eac077wu70vqcetkxf';

void main() {
  group('a first Zcash address the wallet cannot send to', () {
    testWidgets('is passed over for their cash, by the reader the request '
        'is held to', (t) async {
      final c = controllerFor(
        FakeWallet(),
        reads: (a) async => a != _otherNetwork,
      );
      final id = await owingBen(c, [
        {'type': 'zec', 'address': _otherNetwork},
        {'type': 'cash'},
      ]);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_settle_apart_ben')), findsOneWidget);
      expect(find.text('Their 2nd choice · Cash'), findsOneWidget);
      expect(
        find.text(
          'Not their first choice: their Zcash address isn’t one this '
          'wallet can send to.',
        ),
        findsOneWidget,
      );
      expect(find.text('Their address can’t be paid'), findsNothing);
    });

    testWidgets('is passed over for somebody joined from their own phone', (
      t,
    ) async {
      final c = controllerFor(
        FakeWallet(),
        reads: (a) async => a != _otherNetwork,
      );
      final (id, ben) = await owingBoundBen(c, [
        {'type': 'zec', 'address': _otherNetwork},
        {'type': 'cash'},
      ]);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(Key('splits_settle_apart_${ben.id}')), findsOneWidget);
      expect(find.text('Their 2nd choice · Cash'), findsOneWidget);
      expect(find.textContaining('add one'), findsNothing);
    });

    testWidgets('with nothing after it, asks for an address the wallet can '
        'pay, not for a first one', (t) async {
      final c = controllerFor(
        FakeWallet(),
        reads: (a) async => a != _otherNetwork,
      );
      final (id, ben) = await owingBoundBen(c, [
        {'type': 'zec', 'address': _otherNetwork},
      ]);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.text('Their address can’t be paid'), findsOneWidget);
      expect(
        find.text('Ask ben for an address this wallet can pay.'),
        findsOneWidget,
      );
      expect(find.textContaining('add one'), findsNothing);
      expect(find.byKey(Key('splits_settle_apart_${ben.id}')), findsNothing);
    });

    testWidgets('one the reader reads is paid by the request, first choice', (
      t,
    ) async {
      const theirs = 'utest1readable0000000000';
      final c = controllerFor(
        FakeWallet(),
        reads: (a) async => a != _otherNetwork,
      );
      final id = await owingBen(c, [
        {'type': 'zec', 'address': theirs},
        {'type': 'cash'},
      ]);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_settle_pay_ben')), findsOneWidget);
      expect(find.byKey(const Key('splits_settle_send')), findsOneWidget);
      expect(find.textContaining('Not their first choice'), findsNothing);
    });

    test('cannotPayBy reads a Zcash payout as the obligation does', () async {
      final c = controllerFor(
        FakeWallet(),
        reads: (a) async => a != _otherNetwork,
      );
      expect(
        await c.cannotPayBy(const Payout(type: 'zec', address: _otherNetwork)),
        'their Zcash address isn’t one this wallet can send to',
      );
      expect(
        await c.cannotPayBy(const Payout(type: 'zec', address: 'u1-not-alnum')),
        'their Zcash address can’t be paid',
      );
      expect(
        await c.cannotPayBy(
          const Payout(type: 'zec', address: 'utest1readable0000000000'),
        ),
        isNull,
      );
      expect(await c.cannotPayBy(const Payout(type: 'cash')), isNull);
    });
  });

  group('a swap the wallet did not send', () {
    Future<SplitsController> failing(
      WidgetTester t,
      WalletSendOutcome outcome,
      _Swaps swaps,
    ) async {
      final c = controllerFor(FakeWallet(outcome: outcome), swaps: swaps);
      final id = await owingBen(c, [
        {
          'type': 'swap',
          'asset': 'USDC',
          'chain': 'base',
          'address': '0x00000000000000000000000000000000000000b0',
        },
      ]);
      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_swap_send')));
      await t.pumpAndSettle();
      return c;
    }

    testWidgets('says the shortfall in ZEC and offers a new quote', (t) async {
      final swaps = _Swaps();
      await failing(
        t,
        const WalletSendOutcome(
          phase: WalletSendPhase.failed,
          error: _insufficient,
        ),
        swaps,
      );
      expect(find.byKey(const Key('splits_swap_outcome')), findsOneWidget);
      expect(
        find.text(
          'Not enough ZEC: this payment needs 0.0101 ZEC including the fee, '
          'and the wallet has 0.00001 ZEC.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('1010000'), findsNothing);
      expect(swaps.quotes, 1);
      await t.tap(find.byKey(const Key('splits_swap_requote')));
      await t.pumpAndSettle();
      expect(swaps.quotes, 2);
      expect(find.byKey(const Key('splits_swap_outcome')), findsNothing);
      expect(find.byKey(const Key('splits_swap_send')), findsOneWidget);
    });

    testWidgets('a cancelled send offers a new quote too', (t) async {
      await failing(
        t,
        const WalletSendOutcome(phase: WalletSendPhase.aborted),
        _Swaps(),
      );
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.byKey(const Key('splits_swap_requote')), findsOneWidget);
    });

    testWidgets('a failure the wallet words otherwise is shown as it came', (
      t,
    ) async {
      await failing(
        t,
        const WalletSendOutcome(
          phase: WalletSendPhase.failed,
          error: 'Network unreachable',
        ),
        _Swaps(),
      );
      expect(find.text('Network unreachable'), findsOneWidget);
      expect(find.byKey(const Key('splits_swap_requote')), findsOneWidget);
    });

    for (final (phase, title) in [
      (WalletSendPhase.succeeded, 'Sent'),
      (WalletSendPhase.pendingBroadcast, 'Not confirmed'),
    ]) {
      testWidgets('a send that went out, or may yet, offers no second one '
          '(${phase.name})', (t) async {
        await failing(
          t,
          WalletSendOutcome(phase: phase, txid: 'tx-1'),
          _Swaps(),
        );
        expect(find.text(title), findsOneWidget);
        expect(find.byKey(const Key('splits_swap_requote')), findsNothing);
        expect(find.byKey(const Key('splits_swap_send')), findsNothing);
      });
    }
  });

  group('how somebody added by name gets paid, saved untouched', () {
    Participant? ben(SplitsController c, String id) =>
        c.bills.firstWhere((b) => b.id == id).bill.participant('ben');

    testWidgets('cash first opens on cash, and Save leaves their list', (
      t,
    ) async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet);
      final id = await owingBen(c, null, payTo: 'u1benpayable0000000001');
      wallet.tick();
      await c.setPayoutFor(
        billId: id,
        id: 'ben',
        payout: const Payout(type: 'cash'),
      );
      final before = ben(c, id)!.payouts.map((p) => p.type).toList();
      expect(before, ['cash', 'zec']);
      await t.pumpWidget(
        app(c, PayoutForScreen(billId: id, id: 'ben', name: 'ben')),
      );
      await t.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is RadioGroup && '${w.groupValue}'.endsWith('.cash'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('splits_address_field')), findsNothing);
      wallet.tick();
      await t.tap(find.byKey(const Key('splits_address_save')));
      await t.pumpAndSettle();
      expect(ben(c, id)!.payouts.map((p) => p.type).toList(), before);
    });

    testWidgets('USDC first with Zcash after: Save leaves both', (t) async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet);
      final id = await owingBen(c, null, payTo: 'u1benpayable0000000001');
      wallet.tick();
      await c.setPayoutFor(
        billId: id,
        id: 'ben',
        payout: const Payout(
          type: 'swap',
          asset: 'USDC',
          chain: 'base',
          address: '0x00000000000000000000000000000000000000b0',
        ),
      );
      await t.pumpWidget(
        app(c, PayoutForScreen(billId: id, id: 'ben', name: 'ben')),
      );
      await t.pumpAndSettle();
      wallet.tick();
      await t.tap(find.byKey(const Key('splits_address_save')));
      await t.pumpAndSettle();
      expect(ben(c, id)!.payouts.map((p) => p.type).toList(), ['swap', 'zec']);
    });

    testWidgets('an edit is saved', (t) async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet);
      final id = await owingBen(c, null, payTo: 'u1benpayable0000000001');
      await t.pumpWidget(
        app(c, PayoutForScreen(billId: id, id: 'ben', name: 'ben')),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_payout_for_cash')));
      await t.pumpAndSettle();
      wallet.tick();
      await t.tap(find.byKey(const Key('splits_address_save')));
      await t.pumpAndSettle();
      expect(ben(c, id)!.payouts.first.type, 'cash');
    });

    testWidgets('somebody with nothing yet is still asked for an address', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      await c.addPerson(billId: id, id: 'ben', name: 'ben');
      await t.pumpWidget(
        app(c, PayoutForScreen(billId: id, id: 'ben', name: 'ben')),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_address_save')));
      await t.pumpAndSettle();
      expect(
        find.text('Nobody can be paid without an address.'),
        findsOneWidget,
      );
    });
  });

  group('the lane a ZEC payment is labelled with', () {
    testWidgets('a transparent address is labelled transparent on its row, '
        'and is not a warning on the review', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c, null, payTo: _p2pkh);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      final row = find.byKey(const Key('splits_settle_pay_ben'));
      expect(
        find.descendant(of: row, matching: find.text('Transparent ZEC')),
        findsOneWidget,
      );
      expect(find.text('Shielded ZEC'), findsNothing);
      await t.tap(find.byKey(const Key('splits_settle_send')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const Key('splits_review_transparent_0')),
        findsNothing,
      );
    });

    testWidgets('a shielded address is labelled shielded, with no '
        'transparent line on the review', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c, null, payTo: _uaShielded);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      final row = find.byKey(const Key('splits_settle_pay_ben'));
      expect(
        find.descendant(of: row, matching: find.text('Shielded ZEC')),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('splits_settle_send')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const Key('splits_review_transparent_0')),
        findsNothing,
      );
    });

    test('by the kind §8.6 reads each address as', () {
      expect(zecLane(_p2pkh), 'Transparent ZEC');
      expect(zecLane(_p2sh), 'Transparent ZEC');
      expect(zecLane(_tex), 'Transparent ZEC');
      expect(zecLane(_sapling), 'Shielded ZEC');
      expect(zecLane(_uaShielded), 'Shielded ZEC');
      expect(zecLane(_uaWithTransparent), 'Shielded ZEC');
      // One §8.6 cannot read claims nothing.
      expect(zecLane('u1benpayable0000000001'), 'ZEC');
      expect(zecLane(null), 'ZEC');
    });
  });

  group('the reference a payee is shown', () {
    const tx =
        'aa00000000000000000000000000000000000000000000000000000000000001';

    List<String> shown(WidgetTester t) => [
      for (final w in t.widgetList<Text>(find.byType(Text)))
        w.data ?? w.textSpan?.toPlainText() ?? '',
      for (final w in t.widgetList<SelectableText>(find.byType(SelectableText)))
        w.data ?? '',
    ];

    testWidgets('arrivals shows enough of it for §14.2', (t) async {
      late SplitsController c;
      await t.runAsync(() async {
        c = SplitsController(
          wallet: FakeWallet(),
          store: BillStore(InMemoryBillStorage()),
          keys: SplitsKeys(store: InMemorySecretStore(), random: Random(5)),
          prices: _Fixed(),
          received: () async => [entries.IncomingTransaction(tx, 1000000)],
          receivedTimes: () async => {tx: DateTime.utc(2026, 9, 14, 18, 30)},
        );
        await c.load();
        final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
        await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
        await closeForSettling(c, id);
        final ben = await SignedPeer.named('ben');
        await c.accept(id, [
          await ben.join(id, name: 'Ben', payTo: 'u1benpayable0000000001'),
          await ben.sign(
            entries.addExpense(
              host: ben.host,
              expenseId: 'x1',
              paidBy: c.me,
              amount: 2000,
              split: <String, dynamic>{
                'type': 'equal',
                'among': [ben.id, c.me]..sort(),
              },
            ),
            id,
          ),
          await ben.sign(
            entries.recordPayment(
              host: ben.host,
              paymentId: 'p1',
              to: c.me,
              amount: 1000,
              reference: tx,
              zatoshi: 1000000,
              paidAtRate: const <String, dynamic>{
                'currency': 'USD',
                'minorUnitsPerZec': 100000,
                'at': '2026-10-28T19:30:00.000Z',
              },
            ),
            id,
          ),
        ]);
      });
      await t.pumpWidget(
        SplitsScope(
          controller: c,
          child: const MaterialApp(home: ArrivalsScreen()),
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      expect(c.arrived, hasLength(1));
      expect(find.text('Confirm it'), findsOneWidget);
      expect(
        checkPayeeReview(
          payment: c.arrived.single.payment,
          visibleText: shown(t),
          absentWords: 'not recorded',
        ),
        isEmpty,
      );
    });

    test('whole when short, else its first 10 characters', () {
      expect(shortReference(tx), 'aa00000000…');
      expect(shortReference('near-intent'), 'near-intent');
      expect(shortReference('abcdefghijkl'), 'abcdefghijkl');
      expect(shortReference('abcdefghijklm'), 'abcdefghij…');
    });

    testWidgets('settle names a withdrawn payment by enough of it too', (
      t,
    ) async {
      final wallet = FakeWallet(
        outcome: const WalletSendOutcome(
          phase: WalletSendPhase.succeeded,
          txid: tx,
        ),
      );
      final c = controllerFor(wallet);
      final id = await owingBen(c, null, payTo: 'u1benpayable0000000001');
      final owed = await c.obligation(id);
      wallet.tick();
      await c.settle(id, owed!);
      final view = c.bills.firstWhere((b) => b.id == id);
      final payment = view.bill.payments.single;
      wallet.tick();
      await c.withdraw(billId: id, entryId: view.paymentEntries[payment.id]!);
      expect(c.lastError, isNull);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.textContaining('(transaction aa00000000…)'), findsOneWidget);
    });
  });

  group('one tap on Pay, one review', () {
    Future<(SplitsController, FakeWallet, _Held, String)> held() async {
      final wallet = FakeWallet();
      final prices = _Held();
      final c = controllerFor(wallet, prices: prices);
      final id = await owingBen(c, null, payTo: 'u1benpayable0000000001');
      return (c, wallet, prices, id);
    }

    testWidgets('Pay is off while the review is being prepared', (t) async {
      final (c, wallet, prices, id) = await held();
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      final asked = prices.asked;
      final pay = find.byKey(const Key('splits_settle_send'));
      await t.tap(pay);
      await t.pump();
      await t.pump();
      expect(prices.asked, asked + 1);
      expect(t.widget<FilledButton>(pay).onPressed, isNull);
      await t.tap(pay, warnIfMissed: false);
      await t.pump();
      prices.answer.complete(100000);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_review_send')), findsOneWidget);
      expect(prices.asked, asked + 1);
      await t.ensureVisible(find.byKey(const Key('splits_review_send')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_review_send')));
      await t.pumpAndSettle();
      expect(wallet.sender.sent, hasLength(1));
      expect(find.text('Sent. Waiting for them to confirm.'), findsOneWidget);
      expect(
        find.text('The bill changed. Check the amounts again.'),
        findsNothing,
      );
    });

    testWidgets('Pay comes back once a review is cancelled', (t) async {
      final (c, wallet, prices, id) = await held();
      prices.answer.complete(100000);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      final pay = find.byKey(const Key('splits_settle_send'));
      await t.tap(pay);
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(t.widget<FilledButton>(pay).onPressed, isNotNull);
      await t.tap(pay);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_review_send')), findsOneWidget);
      expect(wallet.sender.sent, isEmpty);
    });
  });

  group('a swap quote that runs out while it is on screen', () {
    testWidgets('is shown as expired at its deadline, without a tap', (
      t,
    ) async {
      final wallet = FakeWallet();
      final swaps = _Swaps(
        deadline: () => wallet
            .now()
            .add(const Duration(seconds: 2))
            .toUtc()
            .toIso8601String(),
      );
      final c = controllerFor(wallet, swaps: swaps);
      final id = await owingBen(c, [
        {
          'type': 'swap',
          'asset': 'USDC',
          'chain': 'base',
          'address': '0x00000000000000000000000000000000000000b0',
        },
      ]);
      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_swap_send')), findsOneWidget);
      await t.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('splits_swap_send')), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('splits_swap_send')), findsNothing);
      expect(find.text('Quote expired. Get a new one.'), findsOneWidget);
      await t.tap(find.byKey(const Key('splits_swap_requote')));
      await t.pumpAndSettle();
      expect(swaps.quotes, 2);
      expect(find.byKey(const Key('splits_swap_send')), findsOneWidget);
    });

    testWidgets('a quote with time left stays ready', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c, [
        {
          'type': 'swap',
          'asset': 'USDC',
          'chain': 'base',
          'address': '0x00000000000000000000000000000000000000b0',
        },
      ]);
      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      await t.pump(const Duration(minutes: 10));
      expect(find.byKey(const Key('splits_swap_send')), findsOneWidget);
      expect(find.text('They confirm once it arrives.'), findsOneWidget);
    });
  });
}

class _Fixed implements ZecPrices {
  @override
  Future<int?> minorUnitsPerZec(String currency) async => 100000;
}
