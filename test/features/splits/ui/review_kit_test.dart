// The review a payment is sent from, run through the protocol's own §14.2
// check: every fact it lists must be in the text the dialog shows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'settle_send_test.dart'
    show app, controllerFor, owingBen, owingBenWhoPrices;
import 'support/fake_wallet.dart';

Future<List<ReviewFinding>> _review(
  WidgetTester t,
  SplitsController c,
  FakeWallet wallet,
  BillStorage storage,
  String id,
) async {
  await t.pumpWidget(app(c, SettleScreen(billId: id)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('splits_settle_send')));
  await t.pumpAndSettle();
  final shown = [
    for (final w in t.widgetList<Text>(
      find.descendant(
        of: find.byKey(const Key('splits_review')),
        matching: find.byType(Text),
      ),
    ))
      w.data ?? w.textSpan?.toPlainText() ?? '',
    for (final w in t.widgetList<SelectableText>(
      find.descendant(
        of: find.byKey(const Key('splits_review')),
        matching: find.byType(SelectableText),
      ),
    ))
      w.data ?? w.textSpan?.toPlainText() ?? '',
  ];
  late List<ReviewFinding> findings;
  await t.runAsync(() async {
    final obligation = (await c.obligation(id))!;
    final folded = await foldVerified(
      wallet,
      await BillStore(storage).read(id),
      billId: id,
    );
    findings = checkPayerReview(
      obligation: obligation,
      folded: folded,
      visibleText: shown,
      reasonWords: const {},
    );
  });
  return findings;
}

/// Ben's address at the length of a real unified address, so the review
/// shows it shortened.
const _longAddress =
    'u1benpayable0000000000000000000000000000000000000000000000000000000000'
    '00000000000000000000000000000000000000000000000000000000000000000001';

void main() {
  testWidgets('a shortened address still counts as shown (§14.2)', (t) async {
    final wallet = FakeWallet();
    final storage = InMemoryBillStorage();
    final c = controllerFor(wallet, storage);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final ben = otherHost('ben');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'ben', payTo: _longAddress),
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
    final findings = await _review(t, c, wallet, storage, id);
    expect([for (final f in findings) '${f.rule} ${f.fact}'], isEmpty);
    expect(
      t.widget<Text>(find.byKey(const Key('splits_review_address_0'))).data,
      'u1benpayable0 … 00000000001',
    );
  });

  testWidgets('a rate this device set: nothing §14.2 lists is missing', (
    t,
  ) async {
    final wallet = FakeWallet();
    final storage = InMemoryBillStorage();
    final c = controllerFor(wallet, storage);
    final id = await owingBen(c);
    final findings = await _review(t, c, wallet, storage, id);
    expect([for (final f in findings) '${f.rule} ${f.fact}'], isEmpty);
  });

  testWidgets('a rate the payee set: nothing §14.2 lists is missing', (
    t,
  ) async {
    final wallet = FakeWallet();
    final storage = InMemoryBillStorage();
    final c = controllerFor(wallet, storage);
    final (id, _) = await owingBenWhoPrices(c);
    final findings = await _review(t, c, wallet, storage, id);
    expect([for (final f in findings) '${f.rule} ${f.fact}'], isEmpty);
    // The rate line is the figure, and who set it is not on the review.
    final rate = t.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('splits_review')),
        matching: find.byKey(const Key('splits_settle_rate')),
      ),
    );
    expect(rate.data, '1 ZEC = 1000.00 USD');
    expect(find.byKey(const Key('splits_review_setter_paid')), findsNothing);
  });
}
