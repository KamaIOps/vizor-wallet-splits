// The review a payment is sent from, run through the protocol's own §14.2
// check: every fact it lists must be in the text the dialog shows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
        of: find.byType(AlertDialog),
        matching: find.byType(Text),
      ),
    ))
      w.data ?? w.textSpan?.toPlainText() ?? '',
    for (final w in t.widgetList<SelectableText>(
      find.descendant(
        of: find.byType(AlertDialog),
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

void main() {
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
    // The check finds a name anywhere, and the payee's is on the review as
    // its recipient; the rate line itself must say who set it.
    final rate = t.widget<Text>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byKey(const Key('splits_settle_rate')),
      ),
    );
    expect(rate.data, '1 ZEC = 1000.00 USD, priced by ben');
  });
}
