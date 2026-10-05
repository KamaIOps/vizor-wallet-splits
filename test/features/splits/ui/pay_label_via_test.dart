// The pay button names a swap only when the send carries one: with a payout
// fallback chosen for somebody (§14.8), no swap joins the request.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps;

const _deeBad = 'u1deeunreadable00000001';

Future<(SplitsController, FakeWallet, String)> _bill({
  required bool deeFallback,
}) async {
  final wallet = FakeWallet();
  final c = SplitsController(
    wallet: wallet,
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
    swaps: FakeSwaps(),
    // This wallet's reader refuses Dee's first address (§14.6), so the
    // screen falls back to Dee's second payout, cash (§14.8).
    readsAddress: (a) async => a != _deeBad,
  );
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final ben = otherHost('ben');
  final cai = otherHost('cai');
  final dee = otherHost('dee');
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
  if (deeFallback) {
    await c.accept(id, [
      entries.joinBill(
        host: dee,
        name: 'Dee',
        payouts: [
          <String, dynamic>{'type': 'zec', 'address': _deeBad},
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
  await c.closeForSettling(id);
  return (c, wallet, id);
}

String _button(WidgetTester t) => t
    .widget<Text>(
      find.descendant(
        of: find.byKey(const Key('splits_settle_send')),
        matching: find.byType(Text),
      ),
    )
    .data!;

Future<void> _run(WidgetTester t, {required bool deeFallback}) async {
  final (c, wallet, id) = await _bill(deeFallback: deeFallback);
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(home: SettleScreen(billId: id)),
    ),
  );
  await t.pumpAndSettle();
  final label = _button(t);
  await t.tap(find.byKey(const Key('splits_settle_send')));
  await t.pumpAndSettle();
  await t.ensureVisible(find.byKey(const Key('splits_review_send')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('splits_review_send')));
  await t.pumpAndSettle();
  final sent = wallet.sender.sent.single;
  final swapInSend = sent.contains('u1provider');
  expect(swapInSend, !deeFallback);
  expect(label.contains('by swap'), swapInSend);
}

void main() {
  testWidgets('with no fallback, the button names the swap the send carries', (
    t,
  ) async {
    await _run(t, deeFallback: false);
  });

  testWidgets('with a fallback chosen for Dee, it names no swap, and none is '
      'sent', (t) async {
    await _run(t, deeFallback: true);
  });
}
