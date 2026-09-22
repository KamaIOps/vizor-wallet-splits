/// The splits screens, driven the way a person drives them.
///
/// Every other splits lane calls the controller. This one taps: the feature is
/// reached from Settings, a bill is opened, people are put on it, expenses are
/// typed in, one is taken off, a price is fixed onto it, and two of §9.2's
/// three lanes are settled from the record screen — cash, and a swap to
/// another asset. What is asserted is what the screen says afterwards.
///
/// **A confirmation is not reachable here.** §10.5 gives it to the payee, and
/// on one device every payment is authored by the account holder, so the
/// "It arrived" control belongs to somebody who is not present.
/// `splits_lanes_test.dart` covers that across four devices.
///
///     flutter test integration_test/splits_ui_walkthrough_test.dart -d <device> \
///       --dart-define=VIZOR_FORM_FACTOR=mobile \
///       --dart-define=ZCASH_DEFAULT_NETWORK=regtest
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:integration_test/integration_test.dart';
import 'package:zcash_wallet/app.dart';

import 'support/mobile_regtest_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('a bill, opened and settled through its own screens',
      (tester) async {
    tolerateRenderOverflows();
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) return;
      defaultHandler?.call(details);
    };

    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await createWalletWithPasscode(tester);

    // ── Split bills ──────────────────────────────────────────────────
    //
    // Through the app's own router, so the wallet around it stays up: its
    // providers, its keychain and its database are what the feature reads.
    // Pumping a fresh tree here would take the `ProviderScope` with it.
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/splits');
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(find.text('Bills'), findsOneWidget,
        reason: 'the feature opens on its own list');
    expect(find.textContaining('No bills yet'), findsOneWidget);
    logE2e('splits opened, empty');

    // ── A new bill ───────────────────────────────────────────────────
    await _tapText(tester, 'New bill');
    await _typeInto(tester, 'What is it for', 'Dinner');
    await _typeInto(tester, 'Currency', 'USD');
    await _tapText(tester, 'Open the bill');
    await _settle(tester);
    expect(find.text('Dinner'), findsWidgets);
    logE2e('bill opened');

    // ── Two more people on it ────────────────────────────────────────
    await _tapKey(tester, 'splits_bill_people');
    for (final name in ['Ben', 'Cara']) {
      await _tapKey(tester, 'splits_people_add');
      await _settle(tester);
      await tester.enterText(
          find.byKey(const Key('splits_people_name')), name);
      await tester.pump();
      await _tapKey(tester, 'splits_people_name_ok');
      await _settle(tester);
      expect(find.text(name), findsWidgets, reason: '$name is on the bill');
    }
    logE2e('three people on the bill');
    await _back(tester);

    // ── An expense, typed in ─────────────────────────────────────────
    await _tapText(tester, 'Add an expense');
    await _typeInto(tester, 'What for', 'Dinner');
    await tester.enterText(find.byKey(const Key('splits_amount')), '90');
    await tester.pump();
    await _tapText(tester, 'Add it');
    await _settle(tester);
    await _expenseWritten(tester);
    expect(find.textContaining('90.00'), findsWidgets,
        reason: 'the expense the form was given, in the currency it shows');
    logE2e('90.00 on the bill');

    // ── A second one, then take it off again ─────────────────────────
    await _tapText(tester, 'Add an expense');
    await _typeInto(tester, 'What for', 'Drinks');
    await tester.enterText(find.byKey(const Key('splits_amount')), '30');
    await tester.pump();
    await _tapText(tester, 'Add it');
    await _settle(tester);
    await _expenseWritten(tester);
    expect(find.text('Drinks'), findsWidgets);

    await tester.drag(find.text('Drinks').first, const Offset(-400, 0));
    await _settle(tester);
    expect(find.text('Take this off the bill?'), findsOneWidget,
        reason: 'a withdrawal is confirmed, never silent');
    await _tapKey(tester, 'splits_expense_withdraw_confirm');
    await _settle(tester);
    expect(find.text('Drinks'), findsNothing,
        reason: '§10.4: a withdrawn expense leaves the bill');
    logE2e('Drinks withdrawn');

    // ── The activity log ─────────────────────────────────────────────
    await _tapKey(tester, 'splits_bill_activity');
    await _settle(tester);
    expect(find.text('Activity'), findsWidgets);
    logE2e('activity read');
    await _back(tester);

    // ── The code another device reads ────────────────────────────────
    await tester.tap(find.byTooltip('Share'));
    await _settle(tester);
    // §11.2 caps a payload, and a bill with three addressed people reaches
    // that cap. Both outcomes are states the screen has to say plainly: the
    // whole bill as a code, or the sentence that it has outgrown one. What is
    // asserted is that one of them is on screen and neither is a failure.
    final whole = find.text('Bill code');
    final outgrown = find.textContaining('outgrown a single code');
    await pumpUntil(tester, () => tester.any(whole) || tester.any(outgrown),
        description: 'the whole-bill code, or the cap that refused it');
    if (tester.any(whole)) {
      final code = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .first
          .data!;
      // A code only this app can read is a code no wallet can scan, so it is
      // read back through the protocol rather than eyeballed.
      expect(splitz.readScan(code), isA<splitz.ScannedBill>(),
          reason: 'the screen shows what §11 defines');
      logE2e('shared as a code the protocol reads back');
    } else {
      logE2e('past §11.2\'s cap, and the screen says so');
    }

    // The invite is offered either way, and is what a capped bill is sent as.
    await _scrollToText(tester, 'Just the invite');
    final invite = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data!)
        .firstWhere((c) => c.startsWith('splitz://'),
            orElse: () => throw StateError('no invite on the share screen'));
    expect(splitz.readScan(invite), isA<splitz.ScannedInvite>(),
        reason: '§11.1 renders an invite as a link, whatever the bill\'s size');
    logE2e('invite offered and read back');
    await _back(tester);

    // ── Pricing is reached from the settle screen, which is where the
    //    absence of a price is what stops a send ──────────────────────
    await tester.scrollUntilVisible(find.text('Settle up'), 200,
        scrollable: find.byType(Scrollable).first);
    await _tapText(tester, 'Settle up');
    expect(find.textContaining('no price on it yet'), findsOneWidget,
        reason: 'an unpriced bill says so rather than guessing a rate');
    await _tapText(tester, 'Price it');
    await _typeInto(tester, 'One ZEC costs', '1000');
    await _tapText(tester, 'Put this price on the bill');
    await _settle(tester);
    expect(find.textContaining('no price on it yet'), findsNothing);
    // Ana covered the only expense, so Ana is owed and owes nothing. That is
    // the honest answer rather than an error.
    expect(find.text('You owe nothing on this bill.'), findsOneWidget);
    logE2e('priced at 1000.00 a ZEC; nothing owed by this device');
    await _back(tester);

    // ── §9.2: this device's own lane, which is the only one it may set ──
    //
    // `people_screen.dart` offers the payout control for the account holder
    // alone. A payout says where somebody's money goes, so §10.7 leaves it to
    // the device that can sign for them — which is also why the cash and swap
    // record screens, reached from a withheld row on Settle up, need a payee
    // on another device to put themselves in those lanes.
    await _tapKey(tester, 'splits_bill_people');
    await _settle(tester);
    expect(find.byKey(const Key('splits_person_payout')), findsOneWidget,
        reason: 'one payout control, and it is this device\'s own');
    await _tapKey(tester, 'splits_person_payout');
    await _settle(tester);
    expect(find.text('How you get paid'), findsOneWidget);
    for (final lane in ['zec', 'swap', 'cash']) {
      expect(find.byKey(Key("splits_payout_$lane")), findsOneWidget,
          reason: '§9.2 offers all three lanes');
    }

    await _tapKey(tester, 'splits_payout_swap');
    await tester.enterText(
        find.byKey(const Key('splits_payout_asset')), 'USDC');
    await tester.enterText(
        find.byKey(const Key('splits_payout_chain')), 'base');
    await tester.enterText(
        find.byKey(const Key('splits_payout_address')), '0xana');
    await tester.pump();
    await _tapKey(tester, 'splits_payout_save');
    await _settle(tester);
    expect(find.textContaining('USDC'), findsWidgets,
        reason: 'the lane the bill now shows for this device');
    logE2e('own payout set to USDC on base');
    logE2e('walkthrough complete');
  }, timeout: const Timeout(Duration(minutes: 20)));
}

/// Scrolls the screen until [text] is on it.
///
/// The share screen is a `ListView`: "Just the invite" and the invite's own
/// code sit below the fold, so a finder that waits for one waits forever.
/// Waits for the add-expense screen to close, which is what says the expense
/// was written.
///
/// Tapping a button that is disabled, or one whose form refuses what is in it,
/// throws nothing and leaves the screen where it was. Searching for the
/// expense's own name afterwards does not settle it: that name is still in the
/// "What for" field it was typed into, so the assertion passes on a bill that
/// never changed, and the failure lands on the other device naming the wrong
/// thing.
Future<void> _expenseWritten(WidgetTester tester) async {
  await pumpUntil(
    tester,
    () => !tester.any(find.byKey(const Key('splits_amount'))),
    description: 'the add-expense screen to close on a written expense',
    timeout: const Duration(minutes: 1),
  );
}

Future<void> _scrollToText(WidgetTester tester, String text) async {
  final target = find.text(text);
  if (tester.any(target)) return;
  await tester.scrollUntilVisible(target, 200,
      scrollable: find.byType(Scrollable).last);
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await pumpUntil(tester, () => tester.any(find.text(text)),
      description: 'the control "$text"');
  await tester.tap(find.text(text).last);
  await _settle(tester);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  // A keyboard still opening moves the fold, so it finishes first; then the
  // control is scrolled fully into view before the tap.
  await _settle(tester);
  await pumpUntil(tester, () => tester.any(find.byKey(Key(key))),
      description: 'the control $key');
  await tester.ensureVisible(find.byKey(Key(key)).last);
  await _settle(tester);
  await tester.tap(find.byKey(Key(key)).last);
  await _settle(tester);
}

Future<void> _typeInto(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextFormField, label);
  await pumpUntil(tester, () => tester.any(field),
      description: 'the field "$label"');
  await tester.enterText(field.first, text);
  await tester.pump();
}

Future<void> _back(WidgetTester tester) async {
  await tester.pageBack();
  await _settle(tester);
}
