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

/// A provider that cannot be reached.
class _Unreachable extends _Swaps {
  @override
  Future<List<TradableAsset>> tradableAssets() async =>
      throw const SwapException('offline');
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

const _first = 'u1benpayable0000000001';
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
  testWidgets('a swap the provider cannot deliver is passed over for their '
      'second, Zcash, payout without being asked', (t) async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    // USDT on tron is not a route this provider has.
    final id = await owingBen(c, [
      _swap('USDT', 'tron'),
      {'type': 'zec', 'address': _second},
    ]);

    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    // Already on his second choice, and saying why.
    expect(find.byKey(const Key('splits_settle_pay_ben')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('splits_settle_pay_ben')),
        // Labelled by the kind of [_second], which §8.6 cannot read.
        matching: find.text('ZEC'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Not their first choice: USDT on tron can’t be delivered.'),
      findsOneWidget,
    );
    // Picked for the payer, so there is no choice of theirs to take back.
    expect(
      find.byKey(const Key('splits_settle_first_choice_ben')),
      findsNothing,
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

  testWidgets('a first choice that can be paid is not passed over', (t) async {
    final c = controllerFor(FakeWallet());
    // Cash is always payable: it is a preference, not a failure.
    final id = await owingBen(c, [
      {'type': 'cash'},
      {'type': 'zec', 'address': _second},
    ]);
    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    expect(
      find.byKey(const Key('splits_settle_unpayable_ben')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('splits_settle_passed_ben')), findsNothing);
    expect(find.byKey(const Key('splits_settle_send')), findsNothing);
  });

  testWidgets('a provider that cannot be asked passes nothing over', (t) async {
    final c = controllerFor(FakeWallet(), swaps: _Unreachable());
    final id = await owingBen(c, [
      _swap('USDT', 'tron'),
      {'type': 'zec', 'address': _second},
    ]);
    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    expect(
      find.byKey(const Key('splits_settle_unpayable_ben')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('splits_settle_passed_ben')), findsNothing);
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

  group('declaring more than one way', () {
    Future<List<protocol.Payout>> save(
      WidgetTester t,
      SplitsController c,
      String id,
      List<String> taps,
    ) async {
      await t.pumpWidget(app(c, PayoutScreen(billId: id)));
      await t.pumpAndSettle();
      for (final key in taps) {
        await t.ensureVisible(find.byKey(Key(key)));
        await t.tap(find.byKey(Key(key)));
        await t.pumpAndSettle();
      }
      await t.tap(find.byKey(const Key('splits_payout_save')));
      await t.pumpAndSettle();
      return c.bills.single.bill.participant(c.me)!.payouts;
    }

    testWidgets('cash first, Zcash if that does not work', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c, [
        {'type': 'zec', 'address': _first},
      ]);
      final payouts = await save(t, c, id, [
        'splits_payout_cash',
        'splits_payout_also_zec',
      ]);
      expect(payouts.map((p) => (p.type, p.address)), [
        ('cash', null),
        ('zec', 'u1ana000000000000000000'),
      ]);
    });

    testWidgets('Zcash first, cash after it', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c, [
        {'type': 'zec', 'address': _first},
      ]);
      final payouts = await save(t, c, id, ['splits_payout_also_cash']);
      expect(payouts.map((p) => (p.type, p.address)), [
        ('zec', 'u1ana000000000000000000'),
        ('cash', null),
      ]);
    });

    testWidgets('Zcash alone is still declared by address alone', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c, [
        {'type': 'zec', 'address': _first},
      ]);
      expect(await save(t, c, id, const []), isEmpty);
    });

    testWidgets('the screen reopens on what was declared, and keeps a later '
        'swap it does not edit', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c, [
        {'type': 'zec', 'address': _first},
      ]);
      await c.setPayouts(
        billId: id,
        payouts: const [
          protocol.Payout(type: 'cash'),
          protocol.Payout(type: 'zec', address: 'u1ana000000000000000000'),
          protocol.Payout(
            type: 'swap',
            asset: 'USDC',
            chain: 'base',
            address: '0xana',
          ),
        ],
      );
      // Saved untouched: the same three, in the same order.
      final payouts = await save(t, c, id, const []);
      expect(payouts.map((p) => p.type), ['cash', 'zec', 'swap']);
      expect(payouts.last.address, '0xana');
    });
  });
}
