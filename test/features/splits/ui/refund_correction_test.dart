// A refund (§4, a negative total) restated by a removal becomes this
// device's to correct, and the correction form keeps its sign.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

Future<(SplitsController, String, int)> bill(WidgetTester t, int amount) async {
  final c = controllerFor(FakeWallet());
  late String id;
  await t.runAsync(() async {
    await c.load();
    id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    final ben = otherHost('ben');
    final cai = otherHost('cai');
    await c.accept(id, [
      entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
      entries.joinBill(host: cai, name: 'Cai', payTo: 'u1cai'),
      entries.addExpense(
        host: cai,
        expenseId: 'x1',
        paidBy: 'cai',
        amount: amount,
        description: 'Boat',
        split: <String, dynamic>{
          'type': 'equal',
          'among': ['ben', 'cai', c.me]..sort(),
        },
      ),
    ]);
    // The creator takes Ben off: the boat is restated under this device.
    final plan = (await c.removalPlan(id, 'ben'))!;
    expect(plan.complete, isTrue);
    await c.removePerson(billId: id, id: 'ben', confirmed: plan);
  });
  return (c, id, amount);
}

Future<void> correctDescription(
  WidgetTester t,
  SplitsController c,
  String id, {
  String? retype,
}) async {
  final view = c.bills.firstWhere((b) => b.id == id);
  final expense = view.bill.expenses.single;
  final entryId = view.expenseEntries[expense.id]!;
  await t.pumpWidget(
    app(c, AddExpenseScreen(billId: id, editingEntryId: entryId)),
  );
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('splits_description')), 'Boat ride');
  if (retype != null) {
    await t.enterText(find.byKey(const Key('splits_amount')), retype);
  }
  await t.pumpAndSettle();
  await t.ensureVisible(find.byKey(const Key('splits_expense_save')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('splits_expense_save')));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('control: an ordinary restated expense can be corrected', (
    t,
  ) async {
    final (c, id, _) = await bill(t, 3000);
    await correctDescription(t, c, id);
    final e = c.bills.firstWhere((b) => b.id == id).bill.expenses.single;
    expect(e.description, 'Boat ride');
    expect(e.amount, 3000);
  });

  testWidgets('a restated refund is corrected by its author, sign kept', (
    t,
  ) async {
    final (c, id, _) = await bill(t, -3000);
    await correctDescription(t, c, id);
    final e = c.bills.firstWhere((b) => b.id == id).bill.expenses.single;
    expect(
      e.description,
      'Boat ride',
      reason: 'the author corrects a description',
    );
    expect(e.amount, -3000);
  });

  testWidgets('a refund retyped without its sign is refused, not flipped', (
    t,
  ) async {
    final (c, id, _) = await bill(t, -3000);
    await correctDescription(t, c, id, retype: '30.00');
    final e = c.bills.firstWhere((b) => b.id == id).bill.expenses.single;
    expect(e.amount, -3000, reason: 'a refund stays a refund');
    expect(e.description, 'Boat', reason: 'nothing was saved');
    expect(find.textContaining('Keep the minus sign'), findsOneWidget);
  });
}
