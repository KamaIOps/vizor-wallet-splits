/// Split bills, driven in the real app on a device.
///
/// Every other lane around this feature compiles it. This one runs it: the
/// wallet's own bootstrap, its keychain, its filesystem, and the screens a
/// person taps.
///
/// Point it at a seed driver to have it import the development wallets:
///
///     python3 <splitz_wallet>/tool/seed-driver.py <seed-file> --port 39200
///     flutter test integration_test/splits_mobile_test.dart -d <device> \
///       --dart-define=VIZOR_FORM_FACTOR=mobile \
///       --dart-define=SPLITS_SEED_DRIVER_URL=http://127.0.0.1:39200
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zcash_wallet/app.dart';

import 'support/mobile_regtest_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('a bill is opened, spent on and priced, in the wallet',
      (tester) async {
    tolerateRenderOverflows();

    // The wallet syncs in the background against a real endpoint, and a TLS
    // socket closing under it is not this feature failing. Only that is
    // tolerated; anything else still fails the run.
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) {
        logE2e('tolerated socket: ${details.exception}');
        return;
      }
      defaultHandler?.call(details);
    };

    logE2e('pumping the wallet');
    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await createWalletWithPasscode(tester);

    // Through the app's own router, so the wallet around it stays up: its
    // providers, its keychain and its database are what the feature reads.
    // Pumping a fresh tree here would take the ProviderScope with it.
    logE2e('opening split bills');
    final context = tester.element(find.byType(Scaffold).first);
    GoRouter.of(context).push('/splits');
    await tester.pumpAndSettle(const Duration(seconds: 10));

    expect(find.text('Bills'), findsOneWidget);
    expect(find.textContaining('No bills yet'), findsOneWidget);

    logE2e('opening a bill');
    await tester.tap(find.text('New bill'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'What is it for'),
      'Dinner',
    );
    await tester.tap(find.text('Open the bill'));
    await tester.pumpAndSettle();

    // The opener is on the bill, and §9.4's id came off the wallet's own
    // randomness rather than from anything this test supplied.
    expect(find.text('People'), findsOneWidget);
    expect(find.text('Nothing on it yet.'), findsOneWidget);
    expect(find.text('Join'), findsNothing);

    logE2e('adding an expense');
    await tester.tap(find.text('Add an expense'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount'),
      '90.00',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'What for'),
      'Pizza',
    );
    await tester.tap(find.text('Add it'));
    await tester.pumpAndSettle();

    expect(find.text('Pizza'), findsOneWidget);
    expect(find.text('90.00 EUR'), findsOneWidget);

    logE2e('pricing it');
    await tester.scrollUntilVisible(find.text('Settle up'), 200);
    await tester.tap(find.text('Settle up'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no price on it yet'), findsOneWidget);

    await tester.tap(find.text('Price it'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '45.67');
    await tester.tap(find.text('Put this price on the bill'));
    await tester.pumpAndSettle();

    // Priced, and this device is the only person on the bill, so it owes
    // nobody — which is the honest answer rather than an error.
    expect(find.textContaining('no price on it yet'), findsNothing);
    logE2e('split bills: done');
  });
}
