/// Settling a debt the payment request cannot carry — through the screens, on
/// two devices.
///
/// §8.5 puts only a Zcash address in a ZIP 321 request. A payee who wants cash
/// or another asset is reported instead, and the Settle screen offers a way to
/// settle them apart. Reaching that row needs two devices, because
/// `people_screen.dart` offers the payout control to the account holder alone:
/// a payout says where somebody's money goes, so §10.7 leaves it to the device
/// that can sign for them.
///
/// The confirmation needs two devices for the same reason. "It arrived" is the
/// payee's, and on one device every payment is authored by the account holder.
///
///   SPLITS_LANE=cash   the payee takes cash; the payer records it from the
///                      record screen and the payee vouches for it
///   SPLITS_LANE=swap   the payee takes USDC on Base; the payer reaches the
///                      swap screen, which quotes it against a provider
///
///     flutter test integration_test/splits_ui_settle_test.dart -d <A> \
///       --dart-define=SPLITS_PHASE=payer \
///       --dart-define=SPLITS_RELAY_URL=http://127.0.0.1:39300
///
/// `scripts/e2e/splits-ui-settle.sh` runs both and carries the invite across.
library;

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/features/splits/splits_relay.dart';

import 'support/mobile_regtest_flow.dart';

const _phase = String.fromEnvironment('SPLITS_PHASE');
const _invite = String.fromEnvironment('SPLITS_INVITE');
const _lane = String.fromEnvironment('SPLITS_LANE', defaultValue: 'cash');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('device $_phase, $_lane lane', (tester) async {
    tolerateRenderOverflows();
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) return;
      defaultHandler?.call(details);
    };

    expect(const ['payer', 'payee'].contains(_phase), isTrue,
        reason: 'SPLITS_PHASE is payer or payee');
    expect(const ['cash', 'swap'].contains(_lane), isTrue,
        reason: 'SPLITS_LANE is cash or swap');
    expect(splitsRelayUrl, isNotEmpty, reason: 'this lane needs a relay');

    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await createWalletWithPasscode(tester);

    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/splits');
    await tester.pumpAndSettle(const Duration(seconds: 10));

    if (_phase == 'payer') {
      await _payer(tester);
    } else {
      await _payee(tester);
    }
  }, timeout: const Timeout(Duration(minutes: 45)));
}

/// Opens the bill, settles the withheld row apart, and reads the result.
Future<void> _payer(WidgetTester tester) async {
  await _tapText(tester, 'New bill');
  await _typeInto(tester, 'What is it for', 'Apart');
  await _tapText(tester, 'Open the bill');
  await _settle(tester);
  await _sync(tester);

  // The whole bill as a code, taken off the share screen the way a person
  // takes it.
  //
  // The invite alone will not do. `scan_bill_screen.dart` accepts an invite's
  // key and says plainly that the bill itself still has to arrive — it does
  // not navigate and it does not sync, because an invite carries no entries.
  // The bill's own code carries them, and is what opens it on the other
  // phone. This bill is two people and one expense, well inside §11.2's cap.
  await tester.tap(find.byTooltip('Share'));
  await _settle(tester);
  await _reveal(tester, find.text('Bill code'),
      'the whole-bill code on the share screen');
  final code = tester
      .widgetList<SelectableText>(find.byType(SelectableText))
      .map((w) => w.data!)
      .firstWhere((c) => c.startsWith('splitz1:'),
          orElse: () => throw StateError('the share screen showed no bill code'));
  logE2e('BILLCODE $code');
  await _back(tester);

  // 1 · The payee joins from its own device, declares its lane, and puts what
  //     it covered on the bill. Each of those is waited for on the screen.
  await _syncUntilVisible(tester, find.text('Covered'),
      description: "the payee's expense",
      timeout: const Duration(minutes: 25));
  logE2e('the payee joined and spent');

  // 2 · A price is what makes the bill settleable.
  await tester.scrollUntilVisible(find.text('Settle up'), 200,
      scrollable: find.byType(Scrollable).first);
  await _tapText(tester, 'Settle up');
  if (tester.any(find.text('Price it'))) {
    await _tapText(tester, 'Price it');
    await _typeInto(tester, 'One ZEC costs', '1000');
    await _tapText(tester, 'Put this price on the bill');
    await _settle(tester);
  }

  // 3 · §8.5 leaves the payee out of the request and says why, rather than
  //     flattening a lane the request cannot carry.
  await _reveal(tester, find.textContaining('not paid in shielded ZEC'),
      'the withheld payee, reported rather than dropped');
  expect(find.textContaining('not paid in shielded ZEC'), findsOneWidget,
      reason: 'a payee in another lane is reported, never dropped');
  final apart = _keysWithPrefix(tester, 'splits_settle_apart_');
  expect(apart.length, 1, reason: 'one row to settle apart');
  await _tapKeyRevealed(tester, apart.first);

  if (_lane == 'swap') {
    // The swap screen quotes against a provider this lane does not run, so
    // what is asserted is that it says so rather than failing silently.
    expect(find.textContaining('in another asset'), findsWidgets,
        reason: 'the swap screen is where a non-ZEC asset is settled');
    // `initState` asks for a quote on a post-frame callback, so the screen
    // answers by itself: either a quote, with the ZEC leg to send, or the
    // sentence saying why there is none. Both are below the fold on this
    // list, and neither is a failure — what would be is silence.
    final answered = find.byKey(const Key('splits_swap_message'));
    final sendable = find.byKey(const Key('splits_swap_send'));
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(end)) {
      if (tester.any(answered) || tester.any(sendable)) break;
      final scrollables = find.byType(Scrollable);
      for (var i = 0; i < tester.widgetList(scrollables).length; i++) {
        try {
          await tester.scrollUntilVisible(answered, 120,
              scrollable: scrollables.at(i), maxScrolls: 15);
        } on Object {
          // Not in that one.
        }
      }
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(tester.any(answered) || tester.any(sendable), isTrue,
        reason: 'the swap screen says what the provider answered, or why it '
            'could not be asked');
    if (tester.any(answered)) {
      final said = tester.widget<Text>(answered).data;
      logE2e('swap screen reported: $said');
    } else {
      logE2e('swap screen quoted, and offers the ZEC leg to send');
    }
    return;
  }

  // 4 · Cash has nothing to send, so it goes straight to the record.
  expect(find.textContaining('Record a payment to'), findsOneWidget);
  await _tapKey(tester, 'splits_record_cash');
  await _typeText(tester, 'splits_record_note', 'handed over at the table');
  await _tapKey(tester, 'splits_record_save');
  await _settle(tester);
  await _sync(tester);
  logE2e('cash recorded from the record screen');

  // 5 · A record is a claim. The debt does not move until the payee vouches,
  //     and what says so is the settle screen — not the one that syncs.
  await _syncThenLookOn(
    tester,
    open: () async {
      await tester.scrollUntilVisible(find.text('Settle up'), 200,
          scrollable: find.byType(Scrollable).first);
      await _tapText(tester, 'Settle up');
    },
    target: find.text('You owe nothing on this bill.'),
    description: "the payee's confirmation, on the settle screen",
    timeout: const Duration(minutes: 20),
  );
  logE2e('the bill owes nobody');
}

/// Joins by code, declares a lane, spends, and vouches for what arrives.
Future<void> _payee(WidgetTester tester) async {
  expect(_invite, isNotEmpty, reason: 'the payee is started with the bill code');

  // 1 · Joining is reading a code, on the screen that reads codes. A whole
  //     bill opens straight onto itself; §11.2's invite would only take the
  //     key and leave the bill to arrive some other way.
  await tester.tap(find.byTooltip('Scan a bill'));
  await _settle(tester);
  await _typeIntoField(tester, 'Code', _invite);
  await _tapText(tester, 'Read it');
  await _settle(tester);
  await pumpUntil(tester, () => tester.any(find.text('Apart')),
      description: 'the bill the code carried',
      timeout: const Duration(minutes: 3));
  logE2e('the bill arrived by code');

  // 2 · Reading a bill is not being on it. `bill_screen.dart` says so — "You
  //     are not on this bill yet." — and offers the join, which is what writes
  //     this device's own participant. Until that exists there is no "me" row
  //     on the people screen and so no payout to set.
  await _reveal(tester, find.text('You are not on this bill yet.'),
      'the notice that this device is not on the bill');
  expect(find.text('You are not on this bill yet.'), findsOneWidget);
  await _tapText(tester, 'Join');
  // The notice going away is what says the join landed. What replaces it is
  // not "nowhere yet": `_payoutSummary` reads that only for somebody with
  // neither a payout nor an address, and the wallet gives every participant
  // its own address when it joins — so this device is already in the ZEC lane
  // before it chooses another.
  await _untilGone(tester, find.text('You are not on this bill yet.'),
      description: 'the not-on-this-bill notice, after joining',
      timeout: const Duration(minutes: 3));
  logE2e('joined the bill');

  // 3 · This device's own lane, which is the only one it may set.
  await _tapKey(tester, 'splits_bill_people');
  await _tapKey(tester, 'splits_person_payout');
  await _settle(tester);
  if (_lane == 'swap') {
    await _tapKey(tester, 'splits_payout_swap');
    await _typeText(tester, 'splits_payout_asset', 'USDC');
    await _typeText(tester, 'splits_payout_chain', 'base');
    await _typeText(tester, 'splits_payout_address', '0xpayee');
  } else {
    await _tapKey(tester, 'splits_payout_cash');
  }
  await _tapKey(tester, 'splits_payout_save');
  await _settle(tester);
  await _back(tester);
  logE2e('joined in the $_lane lane');

  // 4 · Something this device covered, so the payer owes it.
  await _tapText(tester, 'Add an expense');
  await _typeInto(tester, 'What for', 'Covered');
  await tester.enterText(find.byKey(const Key('splits_amount')), '60');
  await tester.pump();
  await _tapText(tester, 'Add it');
  await _settle(tester);
  await _sync(tester);
  logE2e('put 60.00 on the bill');

  if (_lane == 'swap') {
    logE2e('swap lane: the payer stops at the provider, nothing to vouch for');
    return;
  }

  // 5 · §10.5: only the payee may say the money arrived, and the control that
  //     says it belongs to the activity screen.
  await _syncThenLookOn(
    tester,
    open: () async => _tapKey(tester, 'splits_bill_activity'),
    target: find.text('It arrived'),
    description: 'the payment the payer recorded, on the activity screen',
    timeout: const Duration(minutes: 20),
  );
  await _tapText(tester, 'It arrived');
  await _settle(tester);
  await _sync(tester);
  logE2e('vouched for the payment');
}

/// Taps the bill screen's own sync control and lets it finish.
///
/// The control belongs to the bill screen alone, and the lane is often
/// somewhere else when it needs one — the settle screen after recording a
/// payment, the activity screen after vouching for one. Returning quietly in
/// that case is worse than failing: every later wait then polls a device that
/// has pushed nothing, and the run dies twenty-five minutes on with a timeout
/// that names the wrong thing. So this walks back to the bill screen, and says
/// so if it cannot find its way there.
Future<void> _sync(WidgetTester tester) async {
  final control = find.byTooltip('Sync');
  // Only pop while there is something to pop. `pageBack` looks for a back
  // button and fails outright when there is none, which is what a lane that
  // is already on the bill screen would hit.
  for (var back = 0; back < 3 && !tester.any(control); back++) {
    if (!_canGoBack(tester)) break;
    await tester.pageBack();
    await _settle(tester);
  }
  expect(control, findsOneWidget,
      reason: 'the bill screen, which is the only screen that can sync');
  await tester.tap(control);
  await _settle(tester);
  await pumpUntil(tester, () => !tester.any(find.text('Syncing…')),
      description: 'the sync to finish',
      timeout: const Duration(minutes: 2));
}

/// Syncs on the bill screen, then looks for [target] on the screen [open]
/// leads to — backing out again if it is not there yet.
///
/// What a lane waits for is rarely on the screen that can sync. "It arrived"
/// belongs to the activity screen, the settled plan to the settle screen, and
/// the sync control to the bill screen alone. Waiting on one while standing on
/// another polls forever and then blames the other device.
Future<void> _syncThenLookOn(
  WidgetTester tester, {
  required Future<void> Function() open,
  required Finder target,
  required String description,
  required Duration timeout,
}) async {
  final end = DateTime.now().add(timeout);
  var polls = 0;
  while (DateTime.now().isBefore(end)) {
    await _sync(tester);
    await open();
    for (var i = 0; i < 3 && !tester.any(target); i++) {
      final scrollables = find.byType(Scrollable);
      for (var j = 0; j < tester.widgetList(scrollables).length; j++) {
        try {
          await tester.scrollUntilVisible(target, 120,
              scrollable: scrollables.at(j), maxScrolls: 15);
        } on Object {
          // Not in that one.
        }
      }
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (tester.any(target)) return;
    await _back(tester);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (++polls % 10 == 0) logE2e('still waiting for $description');
  }
  fail('Timed out waiting for $description.');
}

/// Syncs until [target] is no longer on screen.
///
/// Absence is what some steps assert: a notice that goes away is how the
/// screen says the thing it was about has been done.
Future<void> _untilGone(
  WidgetTester tester,
  Finder target, {
  required String description,
  required Duration timeout,
}) async {
  final end = DateTime.now().add(timeout);
  var polls = 0;
  while (DateTime.now().isBefore(end)) {
    if (!tester.any(target)) return;
    await _sync(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(seconds: 2));
    if (++polls % 15 == 0) logE2e('still waiting for $description');
  }
  fail('Timed out waiting for $description.');
}

/// Syncs until [target] is on screen, scrolling to look for it each time.
///
/// A plain finder cannot see what a `ListView` has not built, so a wait on one
/// spins for its whole timeout while the thing it wants sits below the fold.
Future<void> _syncUntilVisible(
  WidgetTester tester,
  Finder target, {
  required String description,
  required Duration timeout,
}) async {
  final end = DateTime.now().add(timeout);
  var polls = 0;
  while (DateTime.now().isBefore(end)) {
    if (tester.any(target)) return;
    final scrollables = find.byType(Scrollable);
    for (var i = 0; i < tester.widgetList(scrollables).length; i++) {
      try {
        await tester.scrollUntilVisible(target, 120,
            scrollable: scrollables.at(i), maxScrolls: 20);
      } on Object {
        // Not in that one.
      }
      if (tester.any(target)) return;
    }
    await _sync(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(seconds: 2));
    if (++polls % 15 == 0) logE2e('still waiting for $description');
  }
  fail('Timed out waiting for $description.');
}

List<Key> _keysWithPrefix(WidgetTester tester, String prefix) => tester
    .widgetList<Widget>(find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith(prefix)))
    .map((w) => w.key!)
    .toList();

/// Lets the app catch up.
///
/// Generous on purpose: these lanes are run several at a time on one machine,
/// and a fixed pump that is enough for one run is not enough for three. A
/// control that is merely late reads exactly like a control that is missing.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await _reveal(tester, find.text(text), 'the control "$text"');
  await tester.tap(find.text(text).last);
  await _settle(tester);
}

Future<void> _tapKeyRevealed(WidgetTester tester, Key key) async {
  await _reveal(tester, find.byKey(key), 'the control $key');
  await tester.tap(find.byKey(key).last);
  await _settle(tester);
}

/// Brings [target] into the tree, scrolling if it is past the fold.
///
/// Every list on these screens outgrows the viewport: the share screen keeps
/// the invite below the whole-bill code, the settle screen grows a row per
/// payee, and a `ListView` does not build what is not near the viewport.
/// Which scrollable to drive cannot be named in advance, so each is tried.
Future<void> _reveal(WidgetTester tester, Finder target, String what) async {
  if (tester.any(target)) return;
  final scrollables = find.byType(Scrollable);
  for (var i = 0; i < tester.widgetList(scrollables).length; i++) {
    try {
      await tester.scrollUntilVisible(target, 120,
          scrollable: scrollables.at(i), maxScrolls: 30);
      await _settle(tester);
      if (tester.any(target)) return;
    } on Object {
      // That scrollable does not contain it; the next one might.
    }
  }
  await pumpUntil(tester, () => tester.any(target), description: what);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await _reveal(tester, find.byKey(Key(key)), 'the control $key');
  await tester.tap(find.byKey(Key(key)).last);
  await _settle(tester);
}

Future<void> _typeText(WidgetTester tester, String key, String text) async {
  await pumpUntil(tester, () => tester.any(find.byKey(Key(key))),
      description: 'the field $key');
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

Future<void> _typeInto(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextFormField, label);
  await pumpUntil(tester, () => tester.any(field),
      description: 'the field "$label"');
  await tester.enterText(field.first, text);
  await tester.pump();
}

Future<void> _typeIntoField(
    WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextField, label);
  await pumpUntil(tester, () => tester.any(field),
      description: 'the field "$label"');
  await tester.enterText(field.first, text);
  await tester.pump();
}

Future<void> _back(WidgetTester tester) async {
  if (!_canGoBack(tester)) return;
  await tester.pageBack();
  await _settle(tester);
}

/// Whether this screen has somewhere to go back to.
///
/// `pageBack` hunts for a back button and fails the test when there is none,
/// so a loop that pops until it recognises a screen has to ask first.
bool _canGoBack(WidgetTester tester) =>
    tester.any(find.byType(CupertinoNavigationBarBackButton)) ||
    tester.any(find.byType(BackButton));
