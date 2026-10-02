// How somebody added by name gets paid, set by whoever pays them: Zcash, or
// USDC on a chain they name.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'auto_price_and_usdc_test.dart' show app, unpricedBill;
import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps;

const _chains = [
  TradableAsset(assetId: 'eth-usdc', symbol: 'USDC', chain: 'eth', decimals: 6),
  TradableAsset(
    assetId: 'base-usdc',
    symbol: 'USDC',
    chain: 'base',
    decimals: 6,
  ),
];

const _evm = '0x2222222222222222222222222222222222222222';

Future<(SplitsController, String)> _open(WidgetTester t) async {
  late SplitsController c;
  late String id;
  final wallet = FakeWallet();
  await t.runAsync(() async {
    c = SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
      swaps: FakeSwaps(assets: _chains),
    );
    id = await unpricedBill(c, 'USD');
  });
  // A later entry, as it is on a phone whose clock moves.
  wallet.tick();
  await t.pumpWidget(
    app(c, PayoutForScreen(billId: id, id: 'ben', name: 'Ben')),
  );
  await t.pumpAndSettle();
  return (c, id);
}

Future<void> _save(WidgetTester t) async {
  await t.runAsync(() async {
    await t.tap(find.byKey(const Key('splits_address_save')));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Ben can be paid in USDC on a chain, his Zcash address kept '
      'as the way after it', (t) async {
    final (c, id) = await _open(t);
    // Opens on what the bill says: Ben's Zcash address.
    expect(find.text('u1ben'), findsOneWidget);

    await t.tap(find.byKey(const Key('splits_payout_for_usdc')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_payout_chain_base')));
    await t.pumpAndSettle();

    await t.enterText(
      find.byKey(const Key('splits_payout_for_usdc_address')),
      '0xme',
    );
    await _save(t);
    expect(find.text('Invalid EVM address'), findsOneWidget);
    expect(c.bills.single.bill.participant('ben')!.payouts, isEmpty);

    await t.enterText(
      find.byKey(const Key('splits_payout_for_usdc_address')),
      _evm,
    );
    await _save(t);
    final ben = c.bills.single.bill.participant('ben')!;
    expect(ben.payouts.first.type, 'swap');
    expect(ben.payouts.first.asset, 'USDC');
    expect(ben.payouts.first.chain, 'base');
    expect(ben.payouts.first.address, _evm);
    expect(ben.payouts[1].type, 'zec');
    expect(ben.payouts[1].address, 'u1ben');

    // The protocol routes it: the Zcash request this device sends leaves
    // Ben's debt out, as one his first way says to pay by swap.
    late splitz.PayerObligation? owed;
    await t.runAsync(() async {
      await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 5000);
      owed = await c.obligation(id);
    });
    expect(owed!.request.unpayable.single.id, 'ben');
    expect(owed!.request.unpayable.single.reason, 'payout_not_zec');
  });

  testWidgets('no chain picked, nothing saved', (t) async {
    final (c, _) = await _open(t);
    await t.tap(find.byKey(const Key('splits_payout_for_usdc')));
    await t.pumpAndSettle();
    // The address is asked for under the chain it is on, once one is picked.
    expect(
      find.byKey(const Key('splits_payout_for_usdc_address')),
      findsNothing,
    );
    await _save(t);
    expect(find.text('Pick the chain they want USDC on.'), findsOneWidget);
    expect(c.bills.single.bill.participant('ben')!.payouts, isEmpty);
  });

  testWidgets('Zcash still saves an address as before', (t) async {
    final (c, _) = await _open(t);
    await t.enterText(
      find.byKey(const Key('splits_address_field')),
      'u1bennew',
    );
    await _save(t);
    expect(c.bills.single.bill.participant('ben')!.payTo, 'u1bennew');
  });

  testWidgets('cash puts it first, his Zcash address after it', (t) async {
    final (c, _) = await _open(t);
    await t.tap(find.byKey(const Key('splits_payout_for_cash')));
    await t.pumpAndSettle();
    await _save(t);
    final ben = c.bills.single.bill.participant('ben')!;
    expect(ben.payouts.map((p) => p.type), ['cash', 'zec']);
  });

  group('a Zcash address edited keeps their other payouts', () {
    /// Ben, unbound, paid by [payouts] in that order.
    Future<SplitsController> rankedBen(
      WidgetTester t,
      List<Map<String, dynamic>> payouts,
    ) async {
      final (c, id) = await _open(t);
      await t.runAsync(
        () => c.accept(id, [
          entries.joinBill(
            // Written after the join the bill opened with.
            host: WalletBillHost(
              FakeWallet(id: 'ben')..tick(const Duration(seconds: 30)),
            ),
            name: 'Ben',
            payTo: 'u1ben',
            payouts: payouts,
          ),
        ]),
      );
      expect(c.lastError, isNull);
      expect(
        c.bills.single.bill.participant('ben')!.payouts.map((p) => p.type),
        [for (final p in payouts) p['type']],
      );
      // Opened afresh, on what the bill says now.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        app(c, PayoutForScreen(billId: id, id: 'ben', name: 'Ben')),
      );
      await t.pumpAndSettle();
      return c;
    }

    List<(String, String?)> payoutsOf(SplitsController c) => [
      for (final p in c.bills.single.bill.participant('ben')!.payouts)
        (p.type, p.address ?? p.chain),
    ];

    testWidgets('zec first, cash after: the address changes, cash stays', (
      t,
    ) async {
      final c = await rankedBen(t, [
        {'type': 'zec', 'address': 'u1ben'},
        {'type': 'cash'},
      ]);
      await t.enterText(
        find.byKey(const Key('splits_address_field')),
        'u1bennew',
      );
      await _save(t);
      expect(c.lastError, isNull);
      expect(payoutsOf(c), [('zec', 'u1bennew'), ('cash', null)]);
      expect(c.bills.single.bill.participant('ben')!.payTo, 'u1bennew');
    });

    testWidgets('cash first: Zcash chosen goes first, cash after it', (
      t,
    ) async {
      final c = await rankedBen(t, [
        {'type': 'cash'},
        {'type': 'zec', 'address': 'u1ben'},
      ]);
      await t.tap(find.byKey(const Key('splits_payout_for_zec')));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const Key('splits_address_field')),
        'u1bennew',
      );
      await _save(t);
      expect(payoutsOf(c), [('zec', 'u1bennew'), ('cash', null)]);
    });

    testWidgets('USDC first: Zcash chosen goes first, USDC after it', (
      t,
    ) async {
      final c = await rankedBen(t, [
        {'type': 'swap', 'asset': 'USDC', 'chain': 'base', 'address': _evm},
        {'type': 'zec', 'address': 'u1ben'},
      ]);
      await t.tap(find.byKey(const Key('splits_payout_for_zec')));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const Key('splits_address_field')),
        'u1bennew',
      );
      await _save(t);
      expect(payoutsOf(c), [('zec', 'u1bennew'), ('swap', _evm)]);
    });

    testWidgets('cash chosen over zec and USDC keeps both after it', (t) async {
      final c = await rankedBen(t, [
        {'type': 'zec', 'address': 'u1ben'},
        {'type': 'swap', 'asset': 'USDC', 'chain': 'base', 'address': _evm},
      ]);
      await t.tap(find.byKey(const Key('splits_payout_for_cash')));
      await t.pumpAndSettle();
      await _save(t);
      expect(payoutsOf(c), [('cash', null), ('zec', 'u1ben'), ('swap', _evm)]);
    });

    testWidgets('USDC on another chain takes the place of the USDC they had', (
      t,
    ) async {
      final c = await rankedBen(t, [
        {'type': 'swap', 'asset': 'USDC', 'chain': 'eth', 'address': _evm},
        {'type': 'cash'},
        {'type': 'zec', 'address': 'u1ben'},
      ]);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pumpAndSettle();
      final base = find.byKey(const Key('splits_payout_chain_base'));
      await t.ensureVisible(base);
      await t.tap(base);
      await t.pumpAndSettle();
      await _save(t);
      expect(payoutsOf(c), [('swap', _evm), ('cash', null), ('zec', 'u1ben')]);
      expect(
        c.bills.single.bill.participant('ben')!.payouts.first.chain,
        'base',
      );
    });

    testWidgets('an address alone stays an address alone', (t) async {
      final (c, _) = await _open(t);
      await t.enterText(
        find.byKey(const Key('splits_address_field')),
        'u1bennew',
      );
      await _save(t);
      final ben = c.bills.single.bill.participant('ben')!;
      expect(ben.payTo, 'u1bennew');
      expect(ben.payouts, isEmpty);
    });
  });
}
