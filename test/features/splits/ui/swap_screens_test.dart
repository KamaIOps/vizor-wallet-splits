/// Settling a debt in another asset, end to end through the screen.
///
/// No network: the provider is a fake, and the wallet's send is a function.
/// What is asserted is the ordering — what is captured before the send, what
/// is recorded after it, and what is recorded when the send did not land.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'support/closing.dart';

/// A provider that answers without a network.
class FakeSwaps implements SwapProvider {
  FakeSwaps({
    this.assets = const [
      TradableAsset(
        assetId: 'base-usdc',
        symbol: 'USDC',
        chain: 'base',
        decimals: 6,
      ),
    ],
    this.deadline,
    this.reference = 'near-intent-7f3a',
    this.minAmountOut = '9405000',
    this.carriesZec = true,
  });

  /// Whether the listing holds native ZEC; [assets] is listed either way.
  final bool carriesZec;

  final List<TradableAsset> assets;
  final String? minAmountOut;
  final String? deadline;
  final String reference;

  int quotes = 0;

  /// The provider's whole listing: [assets], beside the native ZEC every
  /// deposit is made in.
  @override
  Future<List<TradableAsset>> tradableAssets() async => [
    if (carriesZec) nativeZec,
    ...assets,
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
      amountOut: '9500000',
      minAmountOut: minAmountOut,
      asset: asset,
      deadline: deadline ?? '2099-01-01T00:00:00.000Z',
      reference: reference,
      // What `OneClickSwaps.quote` states: the recipient it asked for.
      recipient: recipient,
    );
  }

  /// What a status query is answered with, and what it was asked about.
  SwapState reports = SwapState.awaitingDeposit;
  final List<String> asked = [];

  @override
  Future<SwapStatus> statusOf(SwapQuote quote) async {
    asked.add(quote.depositAddress);
    return SwapStatus(state: reports);
  }
}

SplitsController controllerFor(FakeWallet wallet, {SwapProvider? swaps}) =>
    SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
      swaps: swaps ?? FakeSwaps(),
    );

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

/// A bill where Ben wants USDC on base and this device owes him 10.00.
Future<String> billOwingSwap(
  SplitsController c, {
  String asset = 'USDC',
  String chain = 'base',
}) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(
      host: ben,
      name: 'ben',
      payouts: [
        <String, dynamic>{
          'type': 'swap',
          'asset': asset,
          'chain': chain,
          'address': '0xben',
        },
      ],
    ),
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
  // One ZEC is a thousand dollars here, so 10.00 is 1_000_000 zatoshi.
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await closeForSettling(c, id);
  return id;
}

void main() {
  testWidgets('the payer sees everything they owe, by how it travels, in one '
      'line', (t) async {
    final c = controllerFor(FakeWallet());
    final id = await billOwingSwap(c);
    // Cat is paid in ZEC and Dan in cash; each paid 20.00 shared with this
    // device, so it owes each 10.00 — 0.01 ZEC at 1000.00 USD a ZEC.
    for (final (name, payout) in [
      (
        'cat',
        <String, dynamic>{'type': 'zec', 'address': 'u1catpayable0000000001'},
      ),
      ('dan', <String, dynamic>{'type': 'cash'}),
    ]) {
      final who = otherHost(name);
      await c.accept(id, [
        entries.joinBill(host: who, name: name, payouts: [payout]),
        entries.addExpense(
          host: who,
          expenseId: 'x-$name',
          paidBy: name,
          amount: 2000,
          split: <String, dynamic>{
            'type': 'equal',
            'among': [name, c.me]..sort(),
          },
        ),
      ]);
    }
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(home: SettleScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();
    expect(
      t.widget<Text>(find.byKey(const Key('splits_settle_summary'))).data,
      '0.01 ZEC + 10.00 USD by swap + 10.00 USD in cash',
    );
  });

  group('quoting', () {
    testWidgets('the screen quotes on open and states both legs', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();

      // The bill's own rate decides the ZEC figure, not a live price.
      expect(find.textContaining('0.01 ZEC'), findsOneWidget);
      expect(find.textContaining('USDC on base'), findsOneWidget);
      // The provider's deposit address is where the ZEC goes, and the
      // recipient's payout is named apart, as where the asset arrives.
      expect(find.text('u1provider'), findsOneWidget);
      expect(find.text('0xben'), findsOneWidget);
      // What Ben is guaranteed is the floor, not the quoted figure.
      expect(
        find.text('at least 9.405 USDC on base (quoted 9.5)'),
        findsOneWidget,
      );
    });

    testWidgets('the rate the ZEC was priced at is shown, and checked', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_swap_rate')), findsOneWidget);
      // No feed in this build, so nothing can say the rate is wrong.
      expect(
        find.byKey(const Key('splits_swap_rate_unchecked')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('splits_swap_setter_paid')), findsNothing);
    });

    test('a deposit is refused once the payee has moved where they are '
        'paid', () async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet);
      final id = await billOwingSwap(c);
      final quote = (await c.quoteSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1000,
      ))!;
      expect(quote.recipient, '0xben');

      // Ben names a new address after the quote was taken.
      final ben = otherHost('ben');
      await c.accept(id, [
        entries.joinBill(
          host: ben,
          name: 'ben',
          payouts: [
            <String, dynamic>{
              'type': 'swap',
              'asset': 'USDC',
              'chain': 'base',
              'address': '0xbenNEW',
            },
          ],
        ),
      ]);

      await c.sendSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1000,
        quote: quote,
      );
      expect(wallet.sender.sent, isEmpty);
      expect(c.lastError, contains('Get a new quote'));
    });

    testWidgets('a quote with no floor shows the quoted figure alone', (
      t,
    ) async {
      final c = controllerFor(
        FakeWallet(),
        swaps: FakeSwaps(minAmountOut: null),
      );
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();

      // 9500000 base units of a six-decimal token.
      expect(find.text('9.5 USDC on base'), findsOneWidget);
      expect(find.textContaining('at least'), findsNothing);
    });

    testWidgets('a provider that does not carry the chain says so', (t) async {
      // One symbol on many chains: matching the symbol alone would send the
      // right token to a network Ben cannot reach.
      final c = controllerFor(
        FakeWallet(),
        swaps: FakeSwaps(
          assets: const [
            TradableAsset(
              assetId: 'eth-usdc',
              symbol: 'USDC',
              chain: 'eth',
              decimals: 6,
            ),
          ],
        ),
      );
      final id = await billOwingSwap(c, chain: 'base');

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();

      expect(
        find.textContaining('does not deliver USDC on base'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('splits_swap_send')), findsNothing);
    });

    testWidgets('a provider that takes no native ZEC is not quoted', (t) async {
      // ZEC as a Solana token is listed by 1Click beside native ZEC; a
      // Zcash wallet cannot deposit it.
      final swaps = FakeSwaps(
        carriesZec: false,
        assets: const [
          TradableAsset(
            assetId: 'base-usdc',
            symbol: 'USDC',
            chain: 'base',
            decimals: 6,
          ),
          TradableAsset(
            assetId:
                '1cs_v1:sol:spl:A7bdiYdS5GjqGFtxf17ppRHtDKPkkRqbKtR27dxvQXaS',
            symbol: 'ZEC',
            chain: 'sol',
            decimals: 8,
          ),
        ],
      );
      final c = controllerFor(FakeWallet(), swaps: swaps);
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();

      expect(
        find.textContaining('does not take ZEC from a Zcash wallet'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('splits_swap_send')), findsNothing);
      expect(swaps.quotes, 0);
    });

    testWidgets('an expired quote offers a new one, not a send', (t) async {
      // Sending against an expired quote pays a price the provider stopped
      // holding.
      final c = controllerFor(
        FakeWallet(),
        swaps: FakeSwaps(deadline: '2020-01-01T00:00:00.000Z'),
      );
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_swap_requote')), findsOneWidget);
      expect(find.byKey(const Key('splits_swap_send')), findsNothing);
      expect(find.textContaining('Quote expired'), findsOneWidget);
    });
  });

  group('sending the ZEC leg', () {
    testWidgets('a landed send records the swap with its reference', (t) async {
      final wallet = FakeWallet(
        outcome: const WalletSendOutcome(
          phase: WalletSendPhase.succeeded,
          txid: 'tx-1',
        ),
      );
      final sent = wallet.sender.sent;
      final c = controllerFor(wallet);
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_swap_send')));
      await t.pumpAndSettle();

      // The ZEC went to the provider's deposit address, for the quoted
      // figure.
      expect(sent.single, contains('u1provider'));
      expect(sent.single, contains('0.01'));

      final payment = c.bills
          .firstWhere((b) => b.id == id)
          .bill
          .payments
          .single;
      expect(payment.method, 'swap');
      // §9.2: the swap's own id, not the Zcash txid.
      expect(payment.reference, 'near-intent-7f3a');
      expect(payment.reference, isNot('tx-1'));
      expect(payment.zatoshi, 1000000);
      // The rate the quote was priced from, as a ZEC payment carries it.
      expect(
        payment.paidAtRate?.minorUnitsPerZec,
        c.bills.single.bill.rate?.minorUnitsPerZec,
      );
      expect(payment.paidAtRate, isNotNull);
      expect(payment.amount, 1000);

      // Sent is not settled. Only Ben can say the asset arrived.
      expect(
        c.bills.firstWhere((b) => b.id == id).bill.confirmedPayments,
        isNot(contains(payment.reference)),
      );
      expect(find.textContaining('confirms when it arrives'), findsOneWidget);
    });

    testWidgets('a send that did not reach the network records NOTHING', (
      t,
    ) async {
      // §14.3: it may still land. Recording it would settle a debt nothing
      // settled; letting a retry through would pay twice.
      final c = controllerFor(
        FakeWallet(
          outcome: const WalletSendOutcome(
            phase: WalletSendPhase.pendingBroadcast,
            statusMessage: 'built but not broadcast',
          ),
        ),
      );
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_swap_send')));
      await t.pumpAndSettle();

      expect(c.bills.firstWhere((b) => b.id == id).bill.payments, isEmpty);
      expect(find.text('Not confirmed'), findsOneWidget);
      expect(find.textContaining('Don’t send again'), findsOneWidget);
    });

    testWidgets('a failed send records nothing and says nothing was spent', (
      t,
    ) async {
      final c = controllerFor(
        FakeWallet(
          outcome: const WalletSendOutcome(
            phase: WalletSendPhase.failed,
            error: 'not enough funds',
          ),
        ),
      );
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_swap_send')));
      await t.pumpAndSettle();

      expect(c.bills.firstWhere((b) => b.id == id).bill.payments, isEmpty);
      expect(find.text('Not sent'), findsOneWidget);
      expect(find.textContaining('not enough funds'), findsOneWidget);
    });
  });

  group('a build with no provider', () {
    testWidgets('says so rather than showing an empty quote', (t) async {
      final c = SplitsController(
        wallet: FakeWallet(),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        relay: const UnconfiguredSplitsRelay(),
      );
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_swap_message')), findsOneWidget);
      expect(find.byKey(const Key('splits_swap_send')), findsNothing);
    });
  });

  group('following a swap up', () {
    /// Sends a swap and returns the bill it settled a debt on.
    Future<String> sent(WidgetTester t, SplitsController c) async {
      final id = await billOwingSwap(c);
      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_swap_send')));
      await t.pumpAndSettle();
      return id;
    }

    testWidgets('a sent swap is followed, and the bill does not carry the '
        'deposit address', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await sent(t, c);

      final held = await c.swapsInFlight(id);
      expect(held.single.reference, 'near-intent-7f3a');
      expect(held.single.depositAddress, 'u1provider');

      // The bill names the swap and nothing about the provider: a deposit
      // address is one provider's routing detail for one swap.
      final payment = c.bills
          .firstWhere((b) => b.id == id)
          .bill
          .payments
          .single;
      expect(payment.reference, 'near-intent-7f3a');
      final encoded = protocol.billToJson(
        c.bills.firstWhere((b) => b.id == id).bill,
      );
      expect(jsonEncode(encoded), isNot(contains('u1provider')));
    });

    testWidgets('the check asks about the deposit address', (t) async {
      final swaps = FakeSwaps();
      final c = controllerFor(FakeWallet(), swaps: swaps);
      final id = await sent(t, c);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.text('Not checked yet'), findsOneWidget);
      await t.tap(
        find.byKey(const Key('splits_inflight_check_near-intent-7f3a')),
      );
      await t.pumpAndSettle();

      expect(swaps.asked, ['u1provider']);
      expect(
        find.textContaining('has not seen the whole deposit'),
        findsOneWidget,
      );
      // Still being followed: nothing has finished.
      expect((await c.swapsInFlight(id)), hasLength(1));
    });

    testWidgets('delivered is NOT settled, and stops the follow-up', (t) async {
      // §10.5 gives the debt to the payee. The provider says it sent the
      // asset; only Ben can say it arrived.
      final swaps = FakeSwaps()..reports = SwapState.delivered;
      final c = controllerFor(FakeWallet(), swaps: swaps);
      final id = await sent(t, c);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(
        find.byKey(const Key('splits_inflight_check_near-intent-7f3a')),
      );
      await t.pumpAndSettle();

      expect(
        find.textContaining('They confirm when it arrives'),
        findsOneWidget,
      );
      // The debt stands until Ben confirms.
      expect(
        c.bills.firstWhere((b) => b.id == id).bill.confirmedPayments,
        isEmpty,
      );
      // And this device stops asking.
      expect(await c.swapsInFlight(id), isEmpty);
    });

    testWidgets('a failed swap stops the follow-up and says where the ZEC '
        'goes', (t) async {
      final swaps = FakeSwaps()..reports = SwapState.failed;
      final c = controllerFor(FakeWallet(), swaps: swaps);
      final id = await sent(t, c);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(
        find.byKey(const Key('splits_inflight_check_near-intent-7f3a')),
      );
      await t.pumpAndSettle();

      expect(find.textContaining('Any refund comes back'), findsOneWidget);
      expect(await c.swapsInFlight(id), isEmpty);
    });

    testWidgets('a refund under way is said, and still followed', (t) async {
      // Not finished: the provider reports failed once the ZEC is back.
      final swaps = FakeSwaps()..reports = SwapState.refunding;
      final c = controllerFor(FakeWallet(), swaps: swaps);
      final id = await sent(t, c);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(
        find.byKey(const Key('splits_inflight_check_near-intent-7f3a')),
      );
      await t.pumpAndSettle();

      expect(find.textContaining('coming back to you'), findsOneWidget);
      expect(find.textContaining('working on it'), findsNothing);
      expect(await c.swapsInFlight(id), hasLength(1));
    });

    testWidgets('a send that did not land is not followed', (t) async {
      // Nothing was recorded, so there is nothing to follow up.
      final c = controllerFor(
        FakeWallet(
          outcome: const WalletSendOutcome(
            phase: WalletSendPhase.pendingBroadcast,
          ),
        ),
      );
      final id = await sent(t, c);
      expect(await c.swapsInFlight(id), isEmpty);
    });

    testWidgets('a swap can be let go without asking again, and is not '
        'cancelled by it', (t) async {
      final swaps = FakeSwaps();
      final c = controllerFor(FakeWallet(), swaps: swaps);
      final id = await sent(t, c);

      await t.pumpWidget(app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();

      const forget = Key('splits_inflight_forget_near-intent-7f3a');
      const confirm = Key('splits_inflight_forget_confirm_near-intent-7f3a');

      // Backing out keeps it.
      await t.tap(find.byKey(forget));
      await t.pumpAndSettle();
      expect(find.textContaining('The swap keeps going'), findsOneWidget);
      await t.tap(find.text('Keep following'));
      await t.pumpAndSettle();
      expect(await c.swapsInFlight(id), hasLength(1));

      await t.tap(find.byKey(forget));
      await t.pumpAndSettle();
      await t.tap(find.byKey(confirm));
      await t.pumpAndSettle();

      expect(await c.swapsInFlight(id), isEmpty);
      expect(find.byKey(forget), findsNothing);
      // Nothing was asked of the provider on the way out.
      expect(swaps.asked, isEmpty);
    });
  });

  group('a deposit that did not resolve', () {
    const pending = WalletSendOutcome(
      phase: WalletSendPhase.pendingBroadcast,
      statusMessage: 'built but not broadcast',
    );

    testWidgets('is not followed by a second quote or a second deposit', (
      t,
    ) async {
      final wallet = FakeWallet(outcome: pending);
      final swaps = FakeSwaps();
      final c = controllerFor(wallet, swaps: swaps);
      final id = await billOwingSwap(c);

      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_swap_send')));
      await t.pumpAndSettle();
      expect(wallet.sender.sent, hasLength(1));
      expect(swaps.quotes, 1);

      // Opened again: nothing is quoted, and a stale quote cannot be sent.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        app(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      expect(swaps.quotes, 1);
      expect(find.textContaining('earlier send'), findsOneWidget);
      expect(find.byKey(const Key('splits_swap_send')), findsNothing);

      final quote = await swaps.quote(
        asset: swaps.assets.single,
        amountInZatoshi: 1000000,
        recipient: '0xben',
        refundTo: 'u1ana',
      );
      await c.sendSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1000,
        quote: quote,
      );
      expect(wallet.sender.sent, hasLength(1));
      expect(c.lastError, contains('earlier send'));
    });

    test('found to have landed, it is recorded by its reference', () async {
      final wallet = FakeWallet(outcome: pending);
      final swaps = FakeSwaps();
      final c = controllerFor(wallet, swaps: swaps);
      final id = await billOwingSwap(c);
      final quote = (await c.quoteSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1000,
      ))!;
      await c.sendSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1000,
        quote: quote,
      );
      expect(c.bills.single.bill.payments, isEmpty);

      await c.resolveSend(id, landed: true);
      expect(c.lastError, isNull);
      expect(await c.pendingSend(id), isNull);
      final payment = c.bills.single.bill.payments.single;
      expect(payment.method, 'swap');
      expect(payment.id, '${c.me}:near-intent-7f3a');
      expect(payment.amount, 1000);
      expect((await c.swapsInFlight(id)).single.reference, 'near-intent-7f3a');
    });
  });

  group('a swap already sent', () {
    test('is not sent a second time from a quote taken before it', () async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet, swaps: FakeSwaps(reference: 'ref-1'));
      final id = await billOwingSwap(c);
      final first = (await c.quoteSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1000,
      ))!;
      // A second quote, as a screen left open would hold, with its own
      // reference so a second record would not merely be a duplicate.
      final second = await FakeSwaps(reference: 'ref-2').quote(
        asset: first.asset,
        amountInZatoshi: first.amountInZatoshi,
        recipient: '0xben',
        refundTo: 'u1ana',
      );
      await c.sendSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1000,
        quote: first,
      );
      expect(wallet.sender.sent, hasLength(1));

      wallet.tick();
      await c.sendSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1000,
        quote: second,
      );
      expect(wallet.sender.sent, hasLength(1));
      // Held on the first deposit, and the payer is told whose confirmation
      // releases it rather than that the bill changed.
      expect(c.lastError, contains('Held until ben confirms'));
      expect(c.bills.single.bill.payments, hasLength(1));
    });

    testWidgets('leaves the settle screen showing it waiting, not payable', (
      t,
    ) async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet);
      final id = await billOwingSwap(c);
      await t.pumpWidget(
        SplitsScope(
          controller: c,
          child: MaterialApp(home: SettleScreen(billId: id)),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_settle_apart_ben')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_swap_send')));
      await t.pumpAndSettle();
      await t.pageBack();
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_settle_apart_ben')), findsNothing);
      expect(find.textContaining('Waiting on'), findsOneWidget);
    });
  });

  test('a quote that asks for a deposit memo is refused', () async {
    // The deposit goes out as a plain request with no memo, and one the
    // provider needs a memo for would be lost.
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    final id = await billOwingSwap(c);
    final quote = (await c.quoteSwap(
      billId: id,
      to: 'ben',
      amountMinorUnits: 1000,
    ))!;
    final withMemo = SwapQuote(
      depositAddress: quote.depositAddress,
      amountInZatoshi: quote.amountInZatoshi,
      amountOut: quote.amountOut,
      asset: quote.asset,
      deadline: quote.deadline,
      depositMemo: '42',
      reference: 'ref-memo',
    );
    await c.sendSwap(
      billId: id,
      to: 'ben',
      amountMinorUnits: 1000,
      quote: withMemo,
    );
    expect(wallet.sender.sent, isEmpty);
    expect(c.lastError, contains('memo'));
  });
}
