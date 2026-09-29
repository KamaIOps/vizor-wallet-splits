/// Settling a debt by a payout the recipient ranked below their first
/// (SPEC.md §14.8): chosen by the payer for one payment, never written to the
/// bill.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// A provider that answers without a network and delivers USDC on base only.
class _Swaps implements SwapProvider {
  final List<String> recipients = [];

  @override
  Future<List<TradableAsset>> tradableAssets() async => const [
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
    recipients.add(recipient);
    return SwapQuote(
      depositAddress: 'u1provider',
      amountInZatoshi: amountInZatoshi,
      amountOut: '9500000',
      minAmountOut: '9405000',
      asset: asset,
      deadline: '2099-01-01T00:00:00.000Z',
      reference: 'near-intent-choice',
      recipient: recipient,
    );
  }

  @override
  Future<SwapStatus> statusOf(SwapQuote quote) async =>
      const SwapStatus(state: SwapState.awaitingDeposit);
}

SplitsController controllerFor(FakeWallet wallet, {SwapProvider? swaps}) =>
    SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
      swaps: swaps ?? _Swaps(),
    );

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

const _second = 'u1benpayable0000000002';

Map<String, dynamic> _swap(String asset, String chain) => {
  'type': 'swap',
  'asset': asset,
  'chain': chain,
  'address': '0xben',
};

/// This device owes Ben 10.00 USD at 1000.00 USD a ZEC, and Ben declared
/// [payouts], most preferred first.
Future<String> owingBen(
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
  return id;
}

void main() {
  testWidgets('a swap the provider cannot deliver is paid by their second, '
      'Zcash, payout', (t) async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    // USDT on tron is not a route this provider has.
    final id = await owingBen(c, [
      _swap('USDT', 'tron'),
      {'type': 'zec', 'address': _second},
    ]);

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    // Nothing to send while Ben's only lane is the swap.
    expect(find.byKey(const Key('splits_settle_send')), findsNothing);

    await t.tap(find.byKey(const Key('splits_settle_other_way_ben')));
    await t.pumpAndSettle();
    expect(find.text('Their 2nd choice'), findsOneWidget);
    await t.tap(find.byKey(const Key('splits_other_way_ben_1')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('splits_settle_pay_ben')), findsOneWidget);
    expect(
      find.text('Their 2nd choice, in the one payment below'),
      findsOneWidget,
    );

    await t.tap(find.byKey(const Key('splits_settle_send')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_review_lower_ben')), findsOneWidget);
    expect(find.text(_second), findsOneWidget);
    await t.tap(find.byKey(const Key('splits_review_send')));
    await t.pumpAndSettle();

    expect(wallet.sender.sent, hasLength(1));
    expect(wallet.sender.sent.single, contains(_second));
    final bill = c.bills.single.bill;
    expect(bill.payments.single.to, 'ben');
    expect(bill.payments.single.method, 'shieldedZec');
    // Nothing rewrote Ben's order: the swap is still his first.
    expect(bill.participant('ben')!.payouts.map((p) => p.type), [
      'swap',
      'zec',
    ]);
  });

  testWidgets('the choice can be taken back before sending', (t) async {
    final c = controllerFor(FakeWallet());
    final id = await owingBen(c, [
      _swap('USDT', 'tron'),
      {'type': 'zec', 'address': _second},
    ]);

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_other_way_ben')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_other_way_ben_1')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('splits_settle_first_choice_ben')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_settle_pay_ben')), findsNothing);
    expect(find.byKey(const Key('splits_settle_send')), findsNothing);
    expect(
      find.byKey(const Key('splits_settle_unpayable_ben')),
      findsOneWidget,
    );
  });

  testWidgets('a lower swap is quoted to that payout', (t) async {
    final swaps = _Swaps();
    final c = controllerFor(FakeWallet(), swaps: swaps);
    // Cash first, which this payer cannot hand over, then USDC on base.
    final id = await owingBen(c, [
      {'type': 'cash'},
      _swap('USDC', 'base'),
    ]);

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_other_way_ben')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_other_way_ben_1')));
    await t.pumpAndSettle();

    expect(find.byType(SwapScreen), findsOneWidget);
    expect(find.byKey(const Key('splits_swap_lower_choice')), findsOneWidget);
    expect(find.textContaining('USDC on base'), findsOneWidget);
    expect(swaps.recipients, ['0xben']);
  });

  test('a payout the payee has since removed is not paid', () async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    final id = await owingBen(c, [
      _swap('USDT', 'tron'),
      {'type': 'zec', 'address': _second},
    ]);
    final chosen = {
      'ben': const protocol.Payout(type: 'zec', address: _second),
    };
    final via = SplitsController.payoutIndexes(c.bills.single.bill, chosen);
    expect(via, {'ben': 1});
    final shown = (await c.obligation(id, via: via))!;

    // Ben replaces that address before the payer sends, later than he
    // first joined.
    final later = FakeWallet(id: 'ben', payTo: 'u1ben')..tick();
    await c.accept(id, [
      entries.joinBill(
        host: WalletBillHost(later),
        name: 'ben',
        payouts: [
          _swap('USDT', 'tron'),
          {'type': 'zec', 'address': 'u1benpayable0000000003'},
        ],
      ),
    ]);
    expect(SplitsController.payoutIndexes(c.bills.single.bill, chosen), {});

    await c.settle(id, shown, via: via);
    expect(wallet.sender.sent, isEmpty);
    expect(c.lastError, contains('changed'));
  });

  test('a choice outside what they declared is refused, not guessed', () async {
    final c = controllerFor(FakeWallet());
    final id = await owingBen(c, [
      {'type': 'zec', 'address': _second},
    ]);
    await expectLater(
      c.obligation(id, via: const {'ben': 1}),
      throwsA(
        isA<protocol.SplitError>().having(
          (e) => e.code,
          'code',
          protocol.SplitCode.payoutNotDeclared,
        ),
      ),
    );
  });
}
