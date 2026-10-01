import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/splits/splits_invite_intake.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/services/incoming_uri_service.dart';

import 'fakes/fake_sync_notifier.dart';

// An opened `splitz:` link is parked in the intake and the bills screens are
// opened to read it — unless the person is part-way through onboarding, or a
// bills screen is already open and reads it in place. The harness is the one
// `app_incoming_link_home_link_test.dart` drives the host with.
void main() {
  const invite = 'splitz:b1?k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  const account = AccountInfo(
    uuid: 'account-1',
    name: 'Account 1',
    order: 0,
    isSeedAnchor: true,
  );

  const walletState = AccountState(
    accounts: [account],
    activeAccountUuid: 'account-1',
    activeAddress: 'u1active',
  );

  Future<(GoRouter, _FakeIncomingUriService, ProviderContainer)> pumpHost(
    WidgetTester tester, {
    required String initialLocation,
  }) async {
    final incomingUris = _FakeIncomingUriService();
    addTearDown(incomingUris.dispose);

    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        for (final path in const [
          '/home',
          '/splits',
          '/onboarding/secret-passphrase',
        ])
          GoRoute(
            path: path,
            builder: (_, _) => Scaffold(body: Text('screen $path')),
          ),
      ],
    );
    addTearDown(router.dispose);

    final container = ProviderContainer(
      overrides: [
        appBootstrapProvider.overrideWithValue(
          _unlockedBootstrapWithWallet(walletState),
        ),
        accountProvider.overrideWith(
          () => _ControllableAccountNotifier(walletState),
        ),
        syncProvider.overrideWith(FakeSyncNotifier.new),
        incomingUriServiceProvider.overrideWithValue(incomingUris),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => AppTheme(
            data: AppThemeData.dark,
            child: buildIncomingLinkHostForTest(router: router, child: child!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (router, incomingUris, container);
  }

  String locationOf(GoRouter router) =>
      router.routerDelegate.currentConfiguration.uri.path;

  testWidgets('an invite opens the bills screens and waits there', (
    tester,
  ) async {
    final (router, uris, container) = await pumpHost(
      tester,
      initialLocation: '/home',
    );
    uris.emit(invite);
    await tester.pumpAndSettle();

    expect(find.text('screen /splits'), findsOneWidget);
    expect(container.read(splitsInviteIntakeProvider), invite);
  });

  testWidgets('an invite during onboarding is parked, not opened', (
    tester,
  ) async {
    final (router, uris, container) = await pumpHost(
      tester,
      initialLocation: '/onboarding/secret-passphrase',
    );
    uris.emit(invite);
    await tester.pumpAndSettle();

    expect(locationOf(router), '/onboarding/secret-passphrase');
    expect(find.text('screen /splits'), findsNothing);
    expect(container.read(splitsInviteIntakeProvider), invite);
  });

  testWidgets('an invite while a bills screen is open opens no second one', (
    tester,
  ) async {
    final (router, uris, container) = await pumpHost(
      tester,
      initialLocation: '/home',
    );
    container.read(splitsInviteIntakeProvider.notifier).screenOpened();
    uris.emit(invite);
    await tester.pumpAndSettle();

    expect(find.text('screen /splits'), findsNothing);
    expect(container.read(splitsInviteIntakeProvider), invite);
  });
}

class _FakeIncomingUriService extends IncomingUriService {
  final StreamController<String> _uris = StreamController<String>.broadcast();

  @override
  Stream<String> get uriStream => _uris.stream;

  @override
  Future<void> initialize() async {}

  void emit(String uri) => _uris.add(uri);

  @override
  Future<void> dispose() async {
    await _uris.close();
  }
}

AppBootstrapState _unlockedBootstrapWithWallet(AccountState accountState) =>
    AppBootstrapState(
      initialLocation: '/home',
      initialAccountState: accountState,
      initialSyncSnapshot: AppSyncSnapshot.empty,
      network: 'main',
      rpcEndpointConfig: defaultRpcEndpointConfig('main'),
      themeMode: ThemeMode.dark,
      privacyModeEnabled: false,
      isPasswordConfigured: true,
      isUnlocked: true,
      passwordRotationRecoveryFailed: false,
    );

class _ControllableAccountNotifier extends AccountNotifier {
  _ControllableAccountNotifier(this._initial);

  final AccountState _initial;

  @override
  FutureOr<AccountState> build() => _initial;
}
