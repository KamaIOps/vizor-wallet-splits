// §14.2, §10.7: the swap leg of a combined send says where the swap delivers,
// that the payee's payout was replaced, and that nobody bound a key to them —
// the same facts a ZEC output and the swap screen carry.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps, controllerFor;

Map<String, dynamic> _usdc(String address) => <String, dynamic>{
  'type': 'swap',
  'asset': 'USDC',
  'chain': 'base',
  'address': address,
};

/// Ben is paid in ZEC and Cai by swap, in one send. With [replace], both
/// payouts are replaced after they joined.
Future<(SplitsController, FakeWallet, String)> _bill({
  required bool replace,
  WalletSendOutcome outcome = const WalletSendOutcome(
    phase: WalletSendPhase.succeeded,
    txid: 'tx-combined',
  ),
}) async {
  final wallet = FakeWallet(outcome: outcome);
  final c = controllerFor(wallet, swaps: FakeSwaps());
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final benWallet = FakeWallet(id: 'ben');
  final caiWallet = FakeWallet(id: 'cai');
  final ben = WalletBillHost(benWallet);
  final cai = WalletBillHost(caiWallet);
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benpayable0000000001'),
    entries.joinBill(host: cai, name: 'Cai', payouts: [_usdc('0xcaifirst')]),
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
  if (replace) {
    benWallet.tick();
    caiWallet.tick();
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benreplaced000000002'),
      entries.joinBill(host: cai, name: 'Cai', payouts: [_usdc('0xcainext')]),
    ]);
  }
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await c.closeForSettling(id);
  return (c, wallet, id);
}

Future<List<String>> _openReview(
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
  expect(find.byKey(const Key('splits_review_swap')), findsOneWidget);
  return [
    for (final w in t.widgetList<Text>(
      find.descendant(
        of: find.byKey(const Key('splits_review')),
        matching: find.byType(Text),
      ),
    ))
      w.data ?? w.textSpan?.toPlainText() ?? '',
  ];
}

void main() {
  testWidgets('a replaced swap payout is flagged, and the kit finds nothing '
      'missing', (t) async {
    final (c, _, id) = await _bill(replace: true);
    expect(c.bills.single.replacedAddresses.map((r) => r.id).toSet(), {
      'ben',
      'cai',
    });
    final shown = await _openReview(t, c, id);
    expect(find.byKey(const Key('splits_review_replaced_ben')), findsOneWidget);
    expect(find.byKey(const Key('splits_review_replaced_cai')), findsOneWidget);
    expect(
      shown.where((s) => s.contains('Cai receives at 0xcainext')),
      hasLength(1),
    );
    expect(find.byKey(const Key('splits_swap_unbound_cai')), findsOneWidget);

    late List<ReviewFinding> findings;
    await t.runAsync(() async {
      findings = checkPayerReview(
        obligation: (await c.obligation(id))!,
        folded: c.bills.single.folded!,
        visibleText: shown,
        // The swap leg's words for a payout that is not ZEC, and for a
        // replaced address.
        reasonWords: const {
          'payout_not_zec': 'in USDC on Base',
          replacedAddressWords: 'Address recently changed.',
        },
      );
    });
    expect([for (final f in findings) '${f.rule} ${f.fact}'], isEmpty);
  });

  testWidgets('an unchanged swap payout carries no change note', (t) async {
    final (c, _, id) = await _bill(replace: false);
    await _openReview(t, c, id);
    expect(find.byKey(const Key('splits_review_replaced_cai')), findsNothing);
    expect(find.text('Address recently changed.'), findsNothing);
    expect(
      find.byKey(const Key('splits_review_swap_recipient')),
      findsOneWidget,
    );
  });

  // §14.3: the combined send ends in the same three states as the ZEC
  // request alone, and the payer is told which.
  Future<void> send(WidgetTester t) async {
    await t.ensureVisible(find.byKey(const Key('splits_review_send')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_review_send')));
    await t.pumpAndSettle();
  }

  testWidgets('a combined send the wallet refuses says it was not sent', (
    t,
  ) async {
    final (c, wallet, id) = await _bill(
      replace: false,
      outcome: const WalletSendOutcome(
        phase: WalletSendPhase.failed,
        error: 'Insufficient balance',
      ),
    );
    await _openReview(t, c, id);
    await send(t);
    expect(wallet.sender.sent, hasLength(1));
    expect(find.text('Not sent'), findsOneWidget);
    expect(c.bills.single.bill.payments, isEmpty);
  });

  testWidgets('a combined send not yet broadcast says so', (t) async {
    final (c, _, id) = await _bill(
      replace: false,
      outcome: const WalletSendOutcome(
        phase: WalletSendPhase.pendingBroadcast,
        txid: 'tx-held',
      ),
    );
    await _openReview(t, c, id);
    await send(t);
    expect(find.text('Built, not sent yet'), findsOneWidget);
    expect(c.bills.single.bill.payments, isEmpty);
  });

  testWidgets('a combined send that went out says sent', (t) async {
    final (c, _, id) = await _bill(replace: false);
    await _openReview(t, c, id);
    await send(t);
    expect(find.text('Sent'), findsOneWidget);
    expect(c.bills.single.bill.payments.map((p) => p.to).toSet(), {
      'ben',
      'cai',
    });
  });
}
