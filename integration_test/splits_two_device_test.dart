/// One bill, two devices, one relay — through the app's own wiring.
///
/// `splitz_host`'s rehearsal proves the protocol converges. This proves the
/// wallet is wired to it: the store the app writes to, the keychain it keeps
/// bill keys in, and the relay `splits_relay.dart` builds from
/// `SPLITS_RELAY_URL`. Each phase runs on its own simulator with a fresh
/// install, so a device holds nothing until it pulls — the bill lives on the
/// relay, and the invite carries the key that opens it.
///
///     python3 <splitz>/tools/relay/server.py --port 39300
///     flutter test integration_test/splits_two_device_test.dart -d <A> \
///       --dart-define=SPLITS_PHASE=create \
///       --dart-define=SPLITS_RELAY_URL=http://127.0.0.1:39300
///     # then, with the invite the create phase printed:
///     flutter test integration_test/splits_two_device_test.dart -d <B> \
///       --dart-define=SPLITS_PHASE=join \
///       --dart-define=SPLITS_INVITE=<invite> \
///       --dart-define=SPLITS_RELAY_URL=http://127.0.0.1:39300
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_host/io.dart';
import 'package:vizor_splitz/vizor_splitz.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/splits/splits_relay.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';

import 'support/mobile_regtest_flow.dart';

const _phase = String.fromEnvironment('SPLITS_PHASE');
const _invite = String.fromEnvironment('SPLITS_INVITE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('phase $_phase', (tester) async {
    tolerateRenderOverflows();
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) return;
      defaultHandler?.call(details);
    };

    expect(
      const ['create', 'join'].contains(_phase),
      isTrue,
      reason: 'SPLITS_PHASE is create or join',
    );
    expect(
      splitsRelayUrl,
      isNotEmpty,
      reason: 'this lane is about the relay; name one',
    );

    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await createWalletWithPasscode(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    final account = container.read(accountProvider).value!;

    // The same pieces `splits_entry_screen.dart` gives the controller: the
    // app's own storage, its keychain, and the relay it builds.
    // Beside the wallet database, exactly where the entry screen puts it.
    final directory = Directory(
      '${File(await getWalletDbPath()).parent.path}/splits',
    );
    final wallet = VizorSplitsWallet(
      accountUuid: account.activeAccountUuid!,
      unifiedFullViewingKey: null,
      sender: WalletSplitsSender(
        payToAddress: null,
        send: (uri) async => throw StateError('this lane sends nothing'),
      ),
    );
    final controller = SplitsController(
      wallet: wallet,
      store: BillStore(FileBillStorage(directory)),
      keys: SplitsKeys(store: wallet.secrets),
      relay: splitsRelay(),
    );
    await controller.load();

    if (_phase == 'create') {
      await controller.createBill(name: 'Dinner', currency: 'USD');
      final bill = controller.bills.single;
      await controller.syncBill(bill.id);
      final invite = await controller.inviteFor(bill.id);
      // The sequencer reads this line and hands it to the join phase. The
      // invite carries the bill id and the key; the log comes from the relay.
      logE2e('INVITE $invite');
      expect(invite, startsWith('splitz://join'),
          reason: '§11.1 renders an invite as a link, not a payload');
      return;
    }

    // --- join --------------------------------------------------------------
    expect(_invite, isNotEmpty, reason: 'the join phase needs the invite');
    expect(controller.bills, isEmpty,
        reason: 'a fresh install holds no bill until it pulls');

    final scanned = splitz.readScan(_invite);
    expect(scanned, isA<splitz.ScannedInvite>());
    final invite = (scanned as splitz.ScannedInvite).invite;

    await controller.acceptKey(invite.billId, invite.key);
    final result = await controller.syncBill(invite.billId);
    expect(result, isNotNull, reason: 'the relay answered');

    await controller.load();
    final bill = controller.bills.singleWhere((b) => b.id == invite.billId);
    logE2e('pulled "${bill.bill.name}" with '
        '${bill.bill.participants.length} participant(s)');
    expect(bill.bill.name, 'Dinner',
        reason: 'the bill the other device opened arrived over the relay');
  });
}
