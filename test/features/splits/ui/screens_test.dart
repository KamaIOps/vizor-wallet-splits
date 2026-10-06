import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet, {SplitsRelay? relay}) =>
    SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: relay ?? const UnconfiguredSplitsRelay(),
    );

Widget app(SplitsController controller, {Widget? home}) => SplitsScope(
  controller: controller,
  child: MaterialApp(home: home ?? const BillsScreen()),
);

void main() {
  testWidgets('an empty device says so, and offers both ways in', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    await t.pumpWidget(app(c));

    expect(find.textContaining('No bills yet'), findsOneWidget);
    expect(find.text('Start a bill'), findsOneWidget);
    expect(find.text('Join a bill'), findsOneWidget);
  });

  testWidgets('an account that cannot be restored is told so', (t) async {
    // No viewing key, so the identity was drawn at random. Invisible in every
    // signature and decisive the day the device is replaced.
    final c = controllerFor(FakeWallet(identitySecret: null));
    await c.load();
    await t.pumpWidget(app(c));
    expect(find.textContaining('can’t be restored'), findsOneWidget);
  });

  testWidgets('opening a bill lands on it, with the opener already on it', (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    await t.pumpWidget(app(c));

    await t.tap(find.text('Start a bill'));
    await t.pumpAndSettle();

    await t.enterText(
      find.widgetWithText(TextFormField, 'What is it for'),
      'Dinner',
    );
    await t.tap(find.text('Open the bill'));
    await t.pumpAndSettle();

    expect(find.text('Dinner'), findsWidgets);
    expect(find.text('Add expense'), findsOneWidget);
    expect(find.text('Nothing on it yet.'), findsOneWidget);
    expect(find.text('Join'), findsNothing, reason: 'the opener has joined');
  });

  testWidgets('a currency that is not three letters is refused in the field', (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    await t.pumpWidget(app(c, home: const NewBillScreen()));

    await t.enterText(
      find.widgetWithText(TextFormField, 'What is it for'),
      'Dinner',
    );
    await t.enterText(find.widgetWithText(TextFormField, 'Currency'), 'EU');
    await t.tap(find.text('Open the bill'));
    await t.pumpAndSettle();

    expect(find.text('Three letters, as in EUR'), findsOneWidget);
    expect(c.bills, isEmpty);
  });

  testWidgets('an expense is added, split, and shown', (t) async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    await t.pumpWidget(app(c, home: BillScreen(billId: id)));
    await t.pumpAndSettle();

    await t.tap(find.text('Add expense'));
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const Key('splits_amount')), '90.00');
    await t.enterText(find.byKey(const Key('splits_description')), 'Pizza');
    await t.tap(find.byKey(const Key('splits_expense_save')));
    await t.pumpAndSettle();

    expect(find.text('Pizza'), findsOneWidget);
    // The row's figure; the currency is the bill's, said once above.
    expect(find.text('€90.00'), findsOneWidget);
    expect(c.lastError, isNull);
  });

  testWidgets('an unpriced bill has nothing to settle, and is not an error', (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    await t.pumpWidget(app(c, home: SettleScreen(billId: id)));
    await t.pumpAndSettle();

    expect(find.textContaining('no price on it yet'), findsOneWidget);
  });

  testWidgets('a failure is put in front of the person', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    await t.pumpWidget(app(c, home: BillScreen(billId: id)));
    await t.pumpAndSettle();

    // No relay in this build. A sync that quietly did nothing would look
    // exactly like one that worked.
    await t.tap(find.byKey(const Key('splits_bill_menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Sync now'));
    await t.pumpAndSettle();
    expect(find.textContaining('no bill relay'), findsOneWidget);
  });

  testWidgets('a scan that is neither a bill nor an invite says which code', (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    await t.pumpWidget(app(c, home: const ScanBillScreen()));

    await t.enterText(find.byType(TextField).first, 'not a splitz anything');
    await t.enterText(find.byKey(const Key('splits_scan_name')), 'Ana');
    await t.pump();
    await t.tap(find.byKey(const Key('splits_scan_read')));
    await t.pumpAndSettle();

    expect(find.textContaining('not a bill code or an invite'), findsOneWidget);
  });

  testWidgets('a bill scanned from another phone opens here', (t) async {
    final theirs = controllerFor(FakeWallet(id: 'ben', payTo: 'u1ben'));
    await theirs.load();
    final id = (await theirs.createBill(name: 'Dinner', currency: 'EUR'))!;
    final payload = await theirs.shareableBill(id);
    expect(payload, isNotNull, reason: 'two entries fit one code');

    final mine = controllerFor(FakeWallet());
    await mine.load();
    await t.pumpWidget(app(mine, home: const ScanBillScreen()));

    await t.enterText(find.byType(TextField).first, payload!);
    await t.pump();
    // Described as soon as it is pasted; taken only on Join.
    expect(find.textContaining('A bill code for “Dinner”'), findsOneWidget);
    expect(mine.bills, isEmpty);
    await t.enterText(find.byKey(const Key('splits_scan_name')), 'Ana');
    await t.pump();
    await t.tap(find.byKey(const Key('splits_scan_read')));
    await t.pumpAndSettle();

    expect(mine.bills.single.id, id);
    expect(
      mine.bills.single.bill.participant(mine.me)?.name,
      'Ana',
      reason: 'Join takes the bill and puts you on it under the name given',
    );
    expect(find.byKey(const Key('splits_bill_join')), findsNothing);
  });

  testWidgets('sharing offers the invite; the bill code is in the menu', (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    await t.pumpWidget(app(c, home: BillScreen(billId: id)));
    await t.pumpAndSettle();

    await t.tap(find.byTooltip('Share'));
    await t.pumpAndSettle();
    expect(find.text('Share this bill'), findsOneWidget);
    expect(find.byKey(const Key('splits_qr_Invite')), findsOneWidget);
    expect(find.text('Bill code'), findsNothing);
    await t.pageBack();
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('splits_bill_menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_bill_code')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_qr_Bill code')), findsOneWidget);
    expect(find.byKey(const Key('splits_qr_Invite')), findsNothing);
    expect(c.lastError, isNull);
  });

  group('a typed figure becomes minor units by integer arithmetic', () {
    test('ordinary figures', () {
      expect(parseMinorUnits('90', exponent: 2), 9000);
      expect(parseMinorUnits('90.00', exponent: 2), 9000);
      expect(parseMinorUnits('90,5', exponent: 2), 9050);
      expect(
        parseMinorUnits('0.29', exponent: 2),
        29,
        reason: '0.29 * 100 is not 29 in binary floating point',
      );
      expect(parseMinorUnits('.5', exponent: 2), 50);
    });

    test('what it refuses', () {
      expect(parseMinorUnits('', exponent: 2), isNull);
      expect(
        parseMinorUnits('90.001', exponent: 2),
        isNull,
        reason: 'a third decimal is not a cent',
      );
      expect(parseMinorUnits('-90', exponent: 2), isNull);
      expect(parseMinorUnits('9 0', exponent: 2), isNull);
      expect(parseMinorUnits('90.0.0', exponent: 2), isNull);
    });

    test('each currency at its own ISO 4217 exponent', () {
      // Yen have no minor unit, dinars have three, and gold has none a
      // figure can be typed at.
      expect(parseAmountIn('6000', 'JPY'), 6000);
      expect(parseAmountIn('60.5', 'JPY'), isNull);
      expect(parseAmountIn('1.234', 'KWD'), 1234);
      expect(parseAmountIn('90.5', 'USD'), 9050);
      expect(parseAmountIn('1', 'XAU'), isNull);
      expect(formatAmount(6000, 'JPY'), contains('6000'));
      expect(formatAmount(6000, 'JPY'), isNot(contains('60.00')));
      expect(formatAmount(1234, 'KWD'), contains('1.234'));
    });

    test('a comma before three digits is refused, not guessed', () {
      // A thousand to one reader, one dinar to another: KWD has three
      // decimals, so both readings are well-formed.
      expect(parseAmountIn('1,000', 'KWD'), isNull);
      expect(parseAmountIn('1,5', 'KWD'), 1500);
      expect(parseAmountIn('1.000', 'KWD'), 1000);
      expect(parseAmountIn('90,5', 'USD'), 9050);
      // A refusal names a figure that would be taken, or why none would.
      expect(figureRefusal('KWD'), contains('12.500'));
      expect(figureRefusal('JPY'), contains('1250'));
      expect(figureRefusal('XAU'), contains('can’t be split here'));
    });

    test('a figure past 64 bits is refused, not wrapped', () {
      // 2^63 - 1 is the largest amount §2.2 can hold.
      expect(
        parseMinorUnits('92233720368547758.07', exponent: 2),
        9223372036854775807,
      );
      expect(parseMinorUnits('92233720368547758.08', exponent: 2), isNull);
      expect(parseMinorUnits('184467440737095516.16', exponent: 2), isNull);
    });

    test('a currency with no minor unit', () {
      expect(parseMinorUnits('123', exponent: 0), 123);
    });
  });
}
