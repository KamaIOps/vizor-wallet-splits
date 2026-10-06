// §14.8, §14.10: a combined send goes out once, whether or not a ZEC payee
// is paid by their second payout (`via`) beside a payee paid by swap in the
// same transaction.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps, controllerFor;

Future<(SplitsController, FakeWallet, String)> _bill({
  required bool benFallsBack,
}) async {
  final wallet = FakeWallet(
    outcome: const WalletSendOutcome(
      phase: WalletSendPhase.succeeded,
      txid: 'tx-combined',
    ),
  );
  final c = controllerFor(wallet, swaps: FakeSwaps());
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final ben = otherHost('ben');
  final cai = otherHost('cai');
  await c.accept(id, [
    entries.joinBill(
      host: ben,
      name: 'Ben',
      payTo: 'u1benpayable0000000001',
      payouts: benFallsBack
          ? [
              // First choice: an asset the provider does not deliver.
              <String, dynamic>{
                'type': 'swap',
                'asset': 'USDC',
                'chain': 'solana',
                'address': 'SoLBen',
              },
              <String, dynamic>{
                'type': 'zec',
                'address': 'u1benpayable0000000001',
              },
            ]
          : null,
    ),
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
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await c.closeForSettling(id);
  return (c, wallet, id);
}

Future<String?> _payThroughScreen(
  WidgetTester t,
  SplitsController c,
  String id,
) async {
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(home: SettleScreen(billId: id)),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('splits_settle_send')));
  await t.pumpAndSettle();
  await t.ensureVisible(find.byKey(const Key('splits_review_send')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('splits_review_send')));
  await t.pumpAndSettle();
  return c.lastError;
}

void main() {
  for (final fallsBack in [false, true]) {
    testWidgets('combined send, Ben falls back to ZEC = $fallsBack', (t) async {
      final (c, wallet, id) = await _bill(benFallsBack: fallsBack);
      final err = await _payThroughScreen(t, c, id);
      // Retry, as an honest payer would after "check the amounts".
      final err2 = wallet.sender.sent.isEmpty
          ? await _payThroughScreen(t, c, id)
          : null;
      expect(
        wallet.sender.sent,
        hasLength(1),
        reason: 'an honest combined send is refused: $err / $err2',
      );
    });
  }
}
