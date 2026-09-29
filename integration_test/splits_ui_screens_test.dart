/// The screens a bill reaches when there is no relay: codes, scanning, and
/// the record a person keeps of themselves.
///
/// A bill travels two ways. Over a relay it syncs, and `splits_lanes_test.dart`
/// covers that. With no relay configured it travels as a code somebody reads
/// out or scans — which is the path this lane runs, deliberately without
/// `SPLITS_RELAY_URL`, so the screens have to say so rather than showing a
/// sync that never resolves.
///
///     flutter test integration_test/splits_ui_screens_test.dart -d <device> \
///       --dart-define=VIZOR_FORM_FACTOR=mobile \
///       --dart-define=ZCASH_DEFAULT_NETWORK=regtest
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/features/splits/ui/screens/share_bill_screen.dart'
    show CodeImage;
import 'package:zcash_wallet/src/features/splits/splits_relay.dart';

import 'support/mobile_regtest_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets(
    'a bill that travels as a code, not over a relay',
    (tester) async {
      tolerateRenderOverflows();
      final defaultHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception is SocketException) return;
        defaultHandler?.call(details);
      };

      expect(
        splitsRelayUrl,
        isEmpty,
        reason: 'this lane is about the path with no relay; name none',
      );

      await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
      await createWalletWithPasscode(tester);

      GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/splits');
      await tester.pumpAndSettle(const Duration(seconds: 10));

      // ── A code that is not one is refused, and says which code it is ──
      //
      // The §12 code stays in the sentence because it is the part that reads the
      // same in every wallet: it is what somebody can be asked to read out.
      await tester.tap(find.text('Join a bill'));
      await _settle(tester);
      expect(find.text('Join a bill'), findsWidgets);
      await _typeIntoField(tester, 'Code', 'splitz1:notacode');
      await _tapText(tester, 'Read it');
      await _settle(tester);
      expect(
        find.textContaining('('),
        findsWidgets,
        reason: 'the refusal names the §12 code it came from',
      );
      logE2e('a damaged code is refused by name');
      await _back(tester);

      // ── A bill of this device's own ──────────────────────────────────
      await _tapText(tester, 'Start a bill');
      await _typeInto(tester, 'What is it for', 'By code');
      await _tapText(tester, 'Open the bill');
      await _settle(tester);

      // Not a failure, and the screen says which of the two it is.
      expect(
        find.text('Not syncing — this bill travels by code'),
        findsOneWidget,
        reason: 'a build with no relay is a state, not a sync that never ends',
      );
      logE2e('no-relay notice shown');

      // ── The whole bill, and the invite, as codes ─────────────────────
      await tester.tap(find.byTooltip('Share'));
      await _settle(tester);
      expect(find.text('Bill code'), findsOneWidget);
      final codes = tester
          .widgetList<CodeImage>(find.byType(CodeImage))
          .map((w) => w.value)
          .toList();
      expect(codes, isNotEmpty);
      final payload = codes.first;
      // Read back through the protocol rather than eyeballed: a code only this
      // app can read is a code no wallet can scan.
      final scannedBill = splitz.readScan(payload);
      expect(scannedBill, isA<splitz.ScannedBill>());
      expect(
        (scannedBill as splitz.ScannedBill).invite,
        isNotNull,
        reason: '§11.2 carries the invite inside the whole-bill payload',
      );
      logE2e('bill code reads back as a bill with an invite');

      // The invite on its own is the other thing this screen offers, and it is
      // a heading further down the list rather than a control.
      await _scrollToText(
        tester,
        'Lets someone join. The bill arrives when they sync.',
      );
      expect(find.textContaining('Lets someone join'), findsOneWidget);
      expect(
        find.text('Invite'),
        findsOneWidget,
        reason: '§11.1 renders the invite as its own code',
      );
      final invite = tester
          .widgetList<CodeImage>(find.byType(CodeImage))
          .map((w) => w.value)
          .firstWhere(
            (c) => c.startsWith('splitz://'),
            orElse: () => throw StateError('no invite on the share screen'),
          );
      expect(
        splitz.readScan(invite),
        isA<splitz.ScannedInvite>(),
        reason: '§11.1 renders an invite as a link',
      );
      logE2e('invite code reads back as an invite');
      await _back(tester);

      // ── The scanner takes the code this device just showed ───────────
      await _back(tester);
      await tester.tap(find.text('Join a bill'));
      await _settle(tester);
      await _typeIntoField(tester, 'Code', payload);
      await _tapText(tester, 'Read it');
      await _settle(tester);
      expect(
        find.text('By code'),
        findsWidgets,
        reason: 'the bill the code carried is the bill on the list',
      );
      logE2e('the code this device showed is a code it can read');

      // ── The record a person keeps of themselves ──────────────────────
      await _tapText(tester, 'By code');
      await _settle(tester);
      await _tapKey(tester, 'splits_bill_people');
      await _settle(tester);
      expect(
        find.byKey(const Key('splits_person_payout')),
        findsOneWidget,
        reason: '§10.7 leaves a payout to the device that can sign for it',
      );
      await _tapKey(tester, 'splits_person_payout');
      await _settle(tester);
      expect(find.text('How you get paid'), findsOneWidget);
      for (final lane in ['zec', 'swap', 'cash']) {
        expect(
          find.byKey(Key('splits_payout_$lane')),
          findsOneWidget,
          reason: '§9.2 offers all three lanes',
        );
      }
      await _tapKey(tester, 'splits_payout_cash');
      await _tapKey(tester, 'splits_payout_save');
      await _settle(tester);
      logE2e('own payout set to cash');

      logE2e('screens walkthrough complete');
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

/// Scrolls the screen until [text] is on it.
///
/// The share screen is a `ListView`: "Lets someone join" and the invite's own
/// code sit below the fold, so a finder that waits for one waits forever.
Future<void> _scrollToText(WidgetTester tester, String text) async {
  final target = find.text(text);
  if (tester.any(target)) return;
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).last,
  );
  await _settle(tester);
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
  await tester.tap(find.text(text).last);
  await _settle(tester);
}

const _billMenuItems = {
  'splits_bill_people',
  'splits_bill_activity',
  'splits_bill_payout',
  'splits_bill_price',
  'splits_bill_sync_now',
  'splits_bill_forget',
};

Future<void> _tapKey(WidgetTester tester, String key) async {
  // People, Activity, How you get paid, Price, Sync now and Remove sit in
  // the bill screen's menu, which is opened first when one is asked for.
  if (_billMenuItems.contains(key) && !tester.any(find.byKey(Key(key)))) {
    await tester.tap(find.byKey(const Key('splits_bill_menu')));
    await _settle(tester);
  }
  // A keyboard still opening moves the fold, so it finishes first; then the
  // control is scrolled fully into view before the tap.
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

/// The scanner's box is a plain `TextField`, not a `TextFormField`.
Future<void> _typeIntoField(
  WidgetTester tester,
  String label,
  String text,
) async {
  final field = find.widgetWithText(TextField, label);
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
