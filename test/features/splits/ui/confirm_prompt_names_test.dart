// The bill screen's prompt to confirm payments names who says they paid.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController _controller() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

/// Dinner, 30.00 USD this device paid, split with Ben and Cara, then the
/// payments named by [payers]: one each, in order, of 5.00 USD.
Future<String> _dinner(SplitsController c, List<String> payers) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  final ben = await SignedPeer.named('ben');
  final cara = await SignedPeer.named('cara');
  final peers = {'Ben': ben, 'Cara': cara};
  await c.accept(id, [
    await ben.join(id, name: 'Ben', payTo: 'u1benpayable0000000001'),
    await cara.join(id, name: 'Cara', payTo: 'u1carapayable000000001'),
  ]);
  final among = [ben.id, cara.id, c.me]..sort();
  await c.accept(id, [
    await ben.sign(
      entries.addExpense(
        host: ben.host,
        expenseId: 'x1',
        paidBy: c.me,
        amount: 3000,
        split: <String, dynamic>{'type': 'equal', 'among': among},
      ),
      id,
    ),
    for (final (i, name) in payers.indexed)
      await peers[name]!.sign(
        entries.recordPayment(
          host: peers[name]!.host,
          paymentId: 'p$i',
          to: c.me,
          amount: 500,
          reference: '${'0' * 62}${i.toString().padLeft(2, '0')}',
          zatoshi: 500000,
        ),
        id,
      ),
  ]);
  return id;
}

Future<void> _open(WidgetTester t, SplitsController c, String id) async {
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(home: BillScreen(billId: id)),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  for (final (payers, prompt) in [
    (['Ben'], 'Ben says they paid you — confirm it'),
    (['Ben', 'Ben'], 'Ben says they paid you 2 times — confirm them'),
    (['Ben', 'Cara'], 'Ben and Cara say they paid you — confirm them'),
  ]) {
    testWidgets('payments from $payers: "$prompt"', (t) async {
      final c = _controller();
      final id = await _dinner(c, payers);
      expect(
        c.bills.single.awaitingMyConfirmation(c.me),
        hasLength(payers.length),
      );
      await _open(t, c, id);
      expect(find.text(prompt), findsOneWidget);
      expect(find.textContaining('somebody'), findsNothing);
    });
  }
}
