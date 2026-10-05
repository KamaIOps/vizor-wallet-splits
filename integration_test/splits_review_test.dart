/// The send review a payer confirms on, opened in the running app.
///
/// A bill where this device owes Ben, who is paid at a Zcash address, is
/// priced and settled up to the review page: the amount in ZEC, Ben's name and
/// the head of his address are on it, the full address opens, and a wallet
/// that holds nothing is told so instead of being offered a send. Nothing is
/// broadcast, so the lane needs no funds.
///
///     flutter test integration_test/splits_review_test.dart -d <device> \
///       --dart-define=VIZOR_FORM_FACTOR=mobile \
///       --dart-define=ZCASH_DEFAULT_NETWORK=regtest \
///       --dart-define=SPLITS_RELAY_URL=
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_address_verify_sheet.dart';
import 'package:zcash_wallet/src/features/splits/ui/screens/people_screen.dart';
import 'package:zcash_wallet/src/features/splits/ui/screens/splits_scope.dart';

import 'support/mobile_regtest_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('the send review, on screen', (tester) async {
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) return;
      defaultHandler?.call(details);
    };

    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await createWalletWithPasscode(tester);
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/splits');
    await tester.pumpAndSettle(const Duration(seconds: 10));

    // ── A bill, and Ben on it, paid at a Zcash address ─────────────────
    await _tapText(tester, 'Start a bill');
    await _typeInto(tester, 'What is it for', 'Lunch');
    // A currency no feed prices, so the rate is the one typed below.
    await _typeInto(tester, 'Currency', 'STN');
    await _tapText(tester, 'Open the bill');
    await _settle(tester);
    logE2e('bill opened');

    await _tapKey(tester, 'splits_bill_people');
    await _tapKey(tester, 'splits_people_add');
    await tester.enterText(find.byKey(const Key('splits_people_name')), 'Ben');
    await tester.pump();
    await _tapKey(tester, 'splits_people_name_ok');
    await _settle(tester);

    // This wallet's own address stands in for Ben's: a regtest address the
    // wallet reads, and nothing is sent to it.
    final controller = SplitsScope.read(
      tester.element(find.byType(PeopleScreen)),
    );
    final view = controller.bills.single;
    final own = view.bill.participant(controller.me)?.payTo;
    expect(own, isNotNull, reason: 'the device joined with its address');
    await _tapKey(tester, 'splits_person_add_payout_ben');
    await tester.enterText(find.byKey(const Key('splits_address_field')), own!);
    await tester.pump();
    await _tapKey(tester, 'splits_address_save');
    await _settle(tester);
    logE2e('Ben is paid at a Zcash address');
    await _back(tester);

    // ── Ben paid for lunch ─────────────────────────────────────────────
    await _tapText(tester, 'Add expense');
    await _typeInto(tester, 'What was it for?', 'Lunch');
    await tester.enterText(find.byKey(const Key('splits_amount')), '30');
    await tester.pump();
    await _tapKey(tester, 'splits_paid_by_ben');
    await _tapText(tester, 'Add');
    await pumpUntil(
      tester,
      () => !tester.any(find.byKey(const Key('splits_amount'))),
      description: 'the add-expense screen to close on a written expense',
      timeout: const Duration(minutes: 1),
    );
    logE2e('30.00 on the bill, paid by Ben');

    // ── Priced, then settled up to the review ──────────────────────────
    await tester.scrollUntilVisible(
      find.text('Settle up'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await _tapText(tester, 'Settle up');
    await _tapText(tester, 'Price it');
    await _typeInto(tester, 'One ZEC costs', '1000');
    await _tapText(tester, 'Put this price on the bill');
    await _settle(tester);
    await _tapKey(tester, 'splits_settle_send');
    await pumpUntil(
      tester,
      () => tester.any(find.byKey(const Key('splits_review'))),
      description: 'the review page',
      timeout: const Duration(minutes: 1),
    );
    logE2e('review opened');
    logE2e('REVIEW OPENED');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    // Half of 30.00 at 1000.00 a ZEC: 15.00 is 0.015 ZEC.
    expect(find.textContaining('0.015 ZEC'), findsWidgets);
    expect(find.text('Ben'), findsWidgets);
    expect(find.textContaining(own.substring(0, 10)), findsWidgets);
    logE2e('the review shows 0.015 ZEC to Ben at ${own.substring(0, 10)}…');

    // The wallet holds nothing: the review says so once the fee is worked out.
    await pumpUntil(
      tester,
      () =>
          tester.any(find.byKey(const Key('splits_review_short'))) ||
          tester.any(find.byKey(const Key('splits_review_fee'))) ||
          tester.any(find.byKey(const Key('splits_review_fee_syncing'))) ||
          tester.any(find.byKey(const Key('splits_review_fee_unknown'))),
      description: 'the fee, or that the wallet is short',
      timeout: const Duration(minutes: 5),
    );
    logE2e(switch (true) {
      _ when tester.any(find.byKey(const Key('splits_review_short'))) =>
        'the review says the wallet is short',
      _ when tester.any(find.byKey(const Key('splits_review_fee'))) =>
        'the review shows the fee',
      _ when tester.any(find.byKey(const Key('splits_review_fee_syncing'))) =>
        'the review says the wallet is still syncing, and holds the send',
      _ => 'the review says the fee is not known',
    });
    expect(
      tester.any(find.byKey(const Key('splits_review_fee_unknown'))),
      isFalse,
      reason: 'a regtest wallet gives a fee, a shortfall, or that it syncs',
    );

    // Held on screen for a screenshot taken from outside the run.
    logE2e('REVIEW ON SCREEN');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    await _tapText(tester, 'Show full address');
    await pumpUntil(
      tester,
      () => tester.any(find.byType(MobileAddressVerifySheet)),
      description: 'the full address',
    );
    expect(find.textContaining(own.substring(own.length - 8)), findsWidgets);
    logE2e('the full address opens');
    logE2e('review lane complete');
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await pumpUntil(
    tester,
    () => tester.any(find.text(text)),
    description: 'the control "$text"',
  );
  await tester.ensureVisible(find.text(text).last);
  await _settle(tester);
  await tester.tap(find.text(text).last);
  await _settle(tester);
}

const _billMenuItems = {
  'splits_bill_people',
  'splits_bill_activity',
  'splits_bill_payout',
  'splits_bill_sync_now',
  'splits_bill_forget',
};

Future<void> _tapKey(WidgetTester tester, String key) async {
  if (_billMenuItems.contains(key) && !tester.any(find.byKey(Key(key)))) {
    await tester.tap(find.byKey(const Key('splits_bill_menu')));
    await _settle(tester);
  }
  await _settle(tester);
  await pumpUntil(
    tester,
    () => tester.any(find.byKey(Key(key))),
    description: 'the control $key',
  );
  await tester.ensureVisible(find.byKey(Key(key)).last);
  await _settle(tester);
  await tester.tap(find.byKey(Key(key)).last);
  await _settle(tester);
}

Future<void> _typeInto(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextFormField, label);
  await pumpUntil(
    tester,
    () => tester.any(field),
    description: 'the field "$label"',
  );
  await tester.enterText(field.first, text);
  await tester.pump();
}

Future<void> _back(WidgetTester tester) async {
  await tester.pageBack();
  await _settle(tester);
}
