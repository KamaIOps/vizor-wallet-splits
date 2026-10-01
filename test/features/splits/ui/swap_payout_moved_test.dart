// A swap quote is sent only to the payout it was asked for: the same
// address, asset and chain.

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps, controllerFor, billOwingSwap;

Future<void> benMoves(
  SplitsController c,
  String id, {
  required String chain,
  required String address,
  String asset = 'USDC',
}) async {
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
          'address': address,
        },
      ],
    ),
  ]);
}

Future<(FakeWallet, SplitsController)> run(
  String chain,
  String address, {
  String asset = 'USDC',
}) async {
  final wallet = FakeWallet(
    outcome: const WalletSendOutcome(
      phase: WalletSendPhase.succeeded,
      txid: 'tx-1',
    ),
  );
  final swaps = FakeSwaps(
    assets: const [
      TradableAsset(
        assetId: 'base-usdc',
        symbol: 'USDC',
        chain: 'base',
        decimals: 6,
      ),
      TradableAsset(
        assetId: 'arb-usdc',
        symbol: 'USDC',
        chain: 'arbitrum',
        decimals: 6,
      ),
    ],
  );
  final c = controllerFor(wallet, swaps: swaps);
  final id = await billOwingSwap(c);
  final quote = (await c.quoteSwap(
    billId: id,
    to: 'ben',
    amountMinorUnits: 1000,
  ))!;
  await benMoves(c, id, chain: chain, address: address, asset: asset);
  await c.sendSwap(billId: id, to: 'ben', amountMinorUnits: 1000, quote: quote);
  return (wallet, c);
}

void main() {
  test('nothing moved: the deposit goes', () async {
    final (w, c) = await run('base', '0xben');
    expect(c.lastError, isNull);
    expect(w.sender.sent, hasLength(1));
  });

  test('the chain written in another case is the same chain', () async {
    final (w, c) = await run('Base', '0xben');
    expect(c.lastError, isNull);
    expect(w.sender.sent, hasLength(1));
  });

  test('address moved: refused', () async {
    final (w, c) = await run('base', '0xbenNEW');
    expect(w.sender.sent, isEmpty);
    expect(c.lastError, contains('Get a new quote'));
  });

  test('chain moved, same address: refused', () async {
    final (w, c) = await run('arbitrum', '0xben');
    expect(w.sender.sent, isEmpty);
    expect(c.lastError, contains('asset or chain'));
  });

  test('asset moved, same chain and address: refused', () async {
    final (w, c) = await run('base', '0xben', asset: 'USDT');
    expect(w.sender.sent, isEmpty);
    expect(c.lastError, contains('asset or chain'));
  });
}
