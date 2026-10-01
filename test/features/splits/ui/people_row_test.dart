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

    final rowArea = find.byKey(const Key('splits_bill_people_row'));
    final row = t.widget<SingleChildScrollView>(
      find.descendant(
        of: rowArea,
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(row.scrollDirection, Axis.horizontal);
    // A row past the screen's edge shows that there is more of it.
    final bar = t.widget<Scrollbar>(
      find.descendant(of: rowArea, matching: find.byType(Scrollbar)),
    );
    expect(bar.thumbVisibility, isTrue);
    final first = t.getRect(find.byKey(const Key('splits_bill_person_p0')));
    final last = t.getRect(find.byKey(const Key('splits_bill_person_p9')));
    expect(last.top, first.top, reason: 'one row, not wrapped');
  });

  testWidgets('the bill menu reads in the app\'s body text', (t) async {
    final c = controllerFor();
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_bill_menu')));
    await t.pumpAndSettle();

    final body = Theme.of(
      t.element(find.byType(BillScreen)),
    ).textTheme.bodyLarge!;
    final shown = t
        .widget<DefaultTextStyle>(
          find
              .ancestor(
                of: find.text('How you get paid'),
                matching: find.byType(DefaultTextStyle),
              )
              .first,
        )
        .style;
    expect(shown.fontSize, body.fontSize);
    expect(shown.letterSpacing, body.letterSpacing);
  });

  testWidgets('the bill shows amounts in its currency, with its sign, and '
      'no ZEC price', (t) async {
    final c = controllerFor();
    late String id;
    await t.runAsync(() async {
      await c.load();
      id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
      await c.addPerson(billId: id, id: 'ben', name: 'Ben');
      await c.addExpense(
        billId: id,
        paidBy: 'ben',
        amountMinorUnits: 2000,
        among: [c.me, 'ben'],
      );
      await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
    });
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();

    expect(find.text(r'$20.00'), findsOneWidget);
    expect(find.textContaining('ZEC'), findsNothing);

    await t.tap(find.byKey(const Key('splits_bill_menu')));
    await t.pumpAndSettle();
    expect(find.text('Price in ZEC'), findsNothing);
  });

  test('a sign goes before the figure, and after any minus', () {
    expect(formatWithSymbol(300000, 'USD'), r'$3000.00');
    expect(formatWithSymbol(-500, 'USD'), r'-$5.00');
    expect(formatWithSymbol(1200, 'CHF'), '12.00 CHF');
  });
}
