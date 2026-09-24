/// A shared-bill invite opened as a link, delivered by the operating system.
///
/// Another participant's bill is made in this process and pushed to the relay;
/// its invite is logged as `INVITE <uri>`, and the driver hands that URI to the
/// simulator with `xcrun simctl openurl`. From there nothing here is
/// simulated: iOS routes the scheme to the app, the runner passes it over
/// `com.zcash.wallet/payment_uri`, the wallet classifies and parks it, opens the
/// bills screens, and the protocol's reader accepts the key and fetches the log.
///
///     python3 <splitz>/tools/relay/server.py --port 39300
///     scripts/e2e/splits-invite-link.sh <simulator-udid>
///
/// The script runs this file with the defines below and does the `openurl`.
///
///     --dart-define=VIZOR_FORM_FACTOR=mobile
///     --dart-define=SPLITS_RELAY_URL=http://127.0.0.1:39300
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splitz_flutter/splitz_flutter.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/features/splits/splits_invite_intake.dart';
import 'package:zcash_wallet/src/providers/app_security_provider.dart';
import 'package:zcash_wallet/src/features/splits/splits_relay.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';

import 'support/mobile_regtest_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets(
    'an opened invite link lands on the bill it names',
    (tester) async {
      tolerateRenderOverflows();
      expect(splitsRelayUrl, isNotEmpty, reason: 'this lane needs a relay');

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

      // Ana, on another phone: her own storage and keys, sharing only the relay.
      final ana = SplitsController(
        wallet: VizorSplitsWallet(
          accountUuid: 'invite-link-lane-ana',
          identitySecret: null,
          sender: WalletSplitsSender(
            payToAddress: null,
            send: (_) async => throw StateError('this lane sends nothing'),
          ),
          secrets: InMemorySecretStore(),
        ),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore()),
        relay: splitsRelay(),
      );
      await ana.load();
      final billId = (await ana.createBill(
        name: 'Invite link lane',
        currency: 'USD',
      ))!;
      expect(
        await ana.syncBill(billId),
        isNotNull,
        reason: 'the bill reached the relay',
      );
      final invite = await ana.inviteFor(billId);

      // Every step the link takes, as it happens, so a run that fails says where.
      final anchor = tester.element(find.byType(Scaffold).first);
      final router = GoRouter.of(anchor);
      router.routerDelegate.addListener(
        () => logE2e(
          'route ${router.routerDelegate.currentConfiguration.uri.path}',
        ),
      );
      ProviderScope.containerOf(anchor).listen<String?>(
        splitsInviteIntakeProvider,
        (_, next) => logE2e('intake ${next == null ? 'taken' : 'parked'}'),
      );
      logE2e('INVITE $invite');

      // The driver opens the link now. It shows the invite and waits for a tap:
      // opening a link is not agreeing to join.
      final join = find.byKey(const Key('splits_scan_read'));
      final shownBy = DateTime.now().add(const Duration(minutes: 3));
      while (!tester.any(join) && DateTime.now().isBefore(shownBy)) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(
        find.textContaining('An invite to'),
        findsOneWidget,
        reason: 'the opened link shows the invite before joining',
      );
      expect(find.byType(BillScreen), findsNothing);
      logE2e('SHOWN');
      await tester.tap(join);

      // Pump until the bill screen names it.
      final title = find.text('Invite link lane');
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (!tester.any(find.byType(BillScreen)) &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle(const Duration(seconds: 2));

      if (!tester.any(find.byType(BillScreen))) {
        // Where the link stopped, in the app's own words.
        final shown = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .whereType<String>()
            .take(40)
            .join(' | ');
        logE2e('NOT JOINED; on screen: $shown');
        final container = ProviderScope.containerOf(anchor);
        logE2e(
          'parked=${container.read(splitsInviteIntakeProvider) != null} '
          'locked=${container.read(appSecurityProvider).requiresUnlock} '
          'at=${router.routerDelegate.currentConfiguration.uri.path}',
        );
      }
      expect(
        find.byType(BillScreen),
        findsOneWidget,
        reason: 'the opened link reached the bill screen',
      );
      expect(title, findsWidgets);
      logE2e('JOINED $billId');
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
