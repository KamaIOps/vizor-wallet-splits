// A USDC payout's address is required however far down the list its field
// sits, and a payer is not offered a swap to an empty one.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps;

/// Every USDC row of the pinned 1Click token list: 15 chains, enough that the
/// address field is below the fold on a 375x667 screen.
List<TradableAsset> _usdc() => [
  for (final r
      in (jsonDecode(
                File(
                  '../Splitz-Protocol/tools/contracts/fixtures/tokens.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>())
    if (r['symbol'] == 'USDC')
      TradableAsset(
        assetId: r['assetId'] as String,
        symbol: 'USDC',
        chain: r['blockchain'] as String,
        decimals: r['decimals'] as int,
      ),
];

SplitsController _controller() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
  prices: const NoZecPrices(),
  swaps: FakeSwaps(assets: _usdc()),
);

Future<String> _bill(SplitsController c) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
  ]);
  await c.setPayouts(billId: id, payouts: const [], displayName: 'Cai');
  expect(c.lastError, isNull);
  return id;
}

/// Opens the payout screen on a phone-sized view, picks USDC on NEAR, and
/// types [address] into the address field when it is not null.
Future<SplitsController> _pickNear(WidgetTester t, {String? address}) async {
  t.view.devicePixelRatio = 2;
  t.view.physicalSize = const Size(750, 1334);
  addTearDown(t.view.reset);
  final c = _controller();
  late String id;
  await t.runAsync(() async => id = await _bill(c));
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            key: const Key('open'),
            onPressed: () => Navigator.of(ctx).push(
              MaterialPageRoute<void>(builder: (_) => PayoutScreen(billId: id)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const Key('open')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('splits_payout_swap')));
  await t.pumpAndSettle();
  final near = find.byKey(const Key('splits_payout_chain_near'));
  await t.dragUntilVisible(near, find.byType(ListView), const Offset(0, -100));
  await t.pumpAndSettle();
  await t.tap(near);
  await t.pumpAndSettle();
  if (address != null) {
    final field = find.byKey(const Key('splits_payout_address'));
    await t.dragUntilVisible(
      field,
      find.byType(ListView),
      const Offset(0, -100),
    );
    await t.enterText(field, address);
    await t.pumpAndSettle();
    // Back to the top, so the field is unbuilt again when Save is tapped.
    await t.dragUntilVisible(
      find.byKey(const Key('splits_payout_swap')),
      find.byType(ListView),
      const Offset(0, 100),
    );
    await t.pumpAndSettle();
  }
  return c;
}

Future<void> _save(WidgetTester t) async {
  await t.runAsync(() async {
    await t.tap(find.byKey(const Key('splits_payout_save')));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await t.pumpAndSettle();
}

List<protocol.Payout> _stored(SplitsController c) =>
    c.bills.single.bill.participant(c.me)!.payouts;

void main() {
  testWidgets('Save with the empty address below the fold writes nothing', (
    t,
  ) async {
    final c = await _pickNear(t);
    expect(find.byKey(const Key('splits_payout_address')), findsNothing);
    await _save(t);
    expect(_stored(c), isEmpty);
    expect(find.byType(PayoutScreen), findsOneWidget);
    expect(
      t.widget<Text>(find.byKey(const Key('splits_payout_unsaved'))).data,
      'Nobody can be paid without an address.',
    );
  });

  testWidgets('an address of spaces below the fold is no address', (t) async {
    final c = await _pickNear(t, address: '   ');
    expect(find.byKey(const Key('splits_payout_address')), findsNothing);
    await _save(t);
    expect(_stored(c), isEmpty);
    expect(find.byKey(const Key('splits_payout_unsaved')), findsOneWidget);
  });

  testWidgets('an address typed below the fold is saved', (t) async {
    final c = await _pickNear(t, address: 'cai.near');
    expect(find.byKey(const Key('splits_payout_address')), findsNothing);
    await _save(t);
    expect(_stored(c).map((p) => (p.type, p.asset, p.chain, p.address)).first, (
      'swap',
      'USDC',
      'near',
      'cai.near',
    ));
    expect(find.byType(PayoutScreen), findsNothing);
  });

  test('a payer is not offered a swap to a blank address', () async {
    final c = _controller();
    Future<String?> by(String? address, {String? chain = 'near'}) =>
        c.cannotPayBy(
          protocol.Payout(
            type: 'swap',
            asset: 'USDC',
            chain: chain,
            address: address,
          ),
        );
    expect(await by(''), contains('incomplete'));
    expect(await by('  '), contains('incomplete'));
    expect(await by(null), contains('incomplete'));
    expect(await by('cai.near', chain: ''), contains('incomplete'));
    expect(await by('cai.near'), isNull);
  });
}
