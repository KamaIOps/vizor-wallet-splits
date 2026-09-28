import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

void main() {
  testWidgets('+ adds somebody, − takes them off, from the bill itself', (
    t,
  ) async {
    final c = controllerFor();
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('splits_bill_add_person')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('splits_people_name')), 'Ana');
    await t.tap(find.byKey(const Key('splits_people_name_ok')));
    await t.pumpAndSettle();
    final ana = c.bills.single.bill.participants
        .firstWhere((p) => p.name == 'Ana')
        .id;
    expect(find.byKey(Key('splits_bill_person_$ana')), findsOneWidget);
    // Names only: nothing on a name takes the person off.
    expect(find.byType(InputChip), findsNothing);

    await t.tap(find.byKey(const Key('splits_bill_remove_person')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('splits_bill_remove_$ana')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_people_remove_confirm')));
    await t.pumpAndSettle();

    expect(c.lastError, isNull);
    expect(c.bills.single.bill.participant(ana), isNull);
    expect(find.byKey(Key('splits_bill_person_$ana')), findsNothing);
  });

  testWidgets('many people scroll sideways rather than wrap', (t) async {
    final c = controllerFor();
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    for (var i = 0; i < 12; i++) {
      await c.addPerson(billId: id, id: 'p$i', name: 'Person number $i');
    }
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();

    final row = t.widget<SingleChildScrollView>(
      find.byKey(const Key('splits_bill_people_row')),
    );
    expect(row.scrollDirection, Axis.horizontal);
    final first = t.getRect(find.byKey(const Key('splits_bill_person_p0')));
    final last = t.getRect(find.byKey(const Key('splits_bill_person_p9')));
    expect(last.top, first.top, reason: 'one row, not wrapped');
  });
}
