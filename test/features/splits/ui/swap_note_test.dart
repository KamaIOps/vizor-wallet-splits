// The payee of a swap is shown what its quote guaranteed would arrive.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'support/closing.dart';
import 'swap_screens_test.dart' show FakeSwaps, billOwingSwap;

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

List<String> textsUnder(Finder root) => find
    .descendant(of: root, matching: find.byWidgetPredicate((w) => true))
    .evaluate()
    .map((e) => e.widget)
    .expand<String>((w) {
      if (w is Text) return [w.data ?? w.textSpan?.toPlainText() ?? ''];
      if (w is SelectableText) {
        return [w.data ?? w.textSpan?.toPlainText() ?? ''];
      }
      return const [];
    })
    .toList();

void main() {
  testWidgets('the payee is shown the floor the payer recorded', (t) async {
    // 1. Payer: the real SwapScreen -> _recordSwap path writes the note.
    final wallet = FakeWallet(
      outcome: const WalletSendOutcome(
        phase: WalletSendPhase.succeeded,
        txid: 'tx-1',
      ),
    );
    final payer = SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
      swaps: FakeSwaps(),
    );
    final payerBill = await billOwingSwap(payer);
    await t.pumpWidget(
      app(
        payer,
        SwapScreen(billId: payerBill, to: 'ben', amountMinorUnits: 1000),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.text('at least 9.405 USDC on base (quoted 9.5)'),
      findsOneWidget,
    );
    await t.tap(find.byKey(const Key('splits_swap_send')));
    await t.pumpAndSettle();
    final written = payer.bills.single.bill.payments.single;
    expect(written.note, 'at least 9.405 USDC on base');

    // 2. Payee: Ben's device receives that same record from the payer.
    final ben = SplitsController(
      wallet: FakeWallet(id: 'ben', payTo: 'u1ben'),
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(4)),
      relay: const UnconfiguredSplitsRelay(),
    );
    await ben.load();
    final ana = otherHost('ana');
    final id = (await ben.createBill(name: 'Dinner', currency: 'USD'))!;
    await ben.addExpense(
      billId: id,
      paidBy: ben.me,
      amountMinorUnits: 2000,
      among: ['ana', ben.me]..sort(),
    );
    await ben.accept(id, [
      entries.joinBill(host: ana, name: 'ana', payTo: 'u1ana'),
      entries.recordPayment(
        host: ana,
        paymentId: written.reference!,
        to: ben.me,
        amount: written.amount,
        method: 'swap',
        reference: written.reference,
        zatoshi: written.zatoshi,
        paidAtRate: protocol.rateToJson(written.paidAtRate!),
        note: written.note,
      ),
    ]);
    await ben.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
    await closeForSettling(ben, id);
    final held = ben.bills.single.bill.payments.single;

    await t.pumpWidget(app(ben, ActivityScreen(billId: id)));
    await t.pumpAndSettle();

    final card = find.byKey(Key('splits_confirm_${held.id}'));
    // Positive control: the confirm card is there and shows the reference.
    expect(card, findsOneWidget);
    expect(find.text('swap near-intent-7f3a'), findsOneWidget);
    final shown = textsUnder(card);
    expect(find.byKey(Key('splits_confirm_note_${held.id}')), findsOneWidget);
    expect(shown, contains('to deliver at least 9.405 USDC on base'));
  });

  testWidgets('a record with no note shows no note line', (t) async {
    final ben = SplitsController(
      wallet: FakeWallet(id: 'ben', payTo: 'u1ben'),
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(4)),
      relay: const UnconfiguredSplitsRelay(),
    );
    await ben.load();
    final ana = otherHost('ana');
    final id = (await ben.createBill(name: 'Dinner', currency: 'USD'))!;
    await ben.addExpense(
      billId: id,
      paidBy: ben.me,
      amountMinorUnits: 2000,
      among: ['ana', ben.me]..sort(),
    );
    await ben.accept(id, [
      entries.joinBill(host: ana, name: 'ana', payTo: 'u1ana'),
      entries.recordPayment(
        host: ana,
        paymentId: 'p1',
        to: ben.me,
        amount: 1000,
        method: 'shieldedZec',
        reference: 'a' * 64,
        zatoshi: 1000000,
      ),
    ]);
    final held = ben.bills.single.bill.payments.single;
    await t.pumpWidget(app(ben, ActivityScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(Key('splits_confirm_${held.id}')), findsOneWidget);
    expect(find.byKey(Key('splits_confirm_note_${held.id}')), findsNothing);
  });
}
