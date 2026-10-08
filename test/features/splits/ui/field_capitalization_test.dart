// Names start each word with a capital and descriptions each sentence, so
// text reads right without the Shift key.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

TextCapitalization _of(WidgetTester t, Finder field) => t
    .widget<TextField>(
      find.descendant(of: field, matching: find.byType(TextField)),
    )
    .textCapitalization;

SplitsController _controller() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

void main() {
  testWidgets('a new bill capitalizes its name and yours', (t) async {
    final c = _controller();
    await c.load();
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: const MaterialApp(home: NewBillScreen()),
      ),
    );
    await t.pumpAndSettle();
    expect(
      _of(t, find.widgetWithText(TextFormField, 'What is it for')),
      TextCapitalization.sentences,
    );
    expect(
      _of(t, find.widgetWithText(TextFormField, 'Your name on this bill')),
      TextCapitalization.words,
    );
    // A currency code is not a sentence.
    expect(
      _of(t, find.widgetWithText(TextFormField, 'Currency')),
      TextCapitalization.characters,
    );
  });

  testWidgets('an expense capitalizes what it was for', (t) async {
    final c = _controller();
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(home: AddExpenseScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();
    expect(
      _of(t, find.byKey(const Key('splits_description'))),
      TextCapitalization.sentences,
    );
    expect(
      _of(t, find.byKey(const Key('splits_amount'))),
      TextCapitalization.none,
    );
  });
}
