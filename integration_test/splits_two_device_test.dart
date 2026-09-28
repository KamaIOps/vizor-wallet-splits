/// One bill, two devices, one relay — through the app's own wiring.
///
/// `splitz_host`'s rehearsal proves the protocol converges. This proves the
/// wallet is wired to it: the store the app writes to, the keychain it keeps
/// bill keys in, the payout address it publishes, and the relay
/// `splits_relay.dart` builds from `SPLITS_RELAY_URL`.
///
/// **The two devices run at the same time and never speak directly.** Each
/// holds its own install for the whole run, so its identity and its account id
/// stand still; everything either one learns about the other arrives by
/// syncing the bill. Each step therefore waits for the other device's entry
/// rather than assuming it, which is what makes this a test of the relay and
/// not of one device's own store.
///
/// One bill, in order: A opens it and publishes an invite; B joins; A puts an
/// expense on it; B puts a second one on it; B settles what the netted bill
/// says it owes; A confirms the money arrived; both sides see a bill that owes
/// nobody.
///
///     python3 <splitz>/tools/relay/server.py --port 39300
///     flutter test integration_test/splits_two_device_test.dart -d <A> \
///       --dart-define=SPLITS_PHASE=a \
///       --dart-define=SPLITS_RELAY_URL=http://127.0.0.1:39300
///
/// `scripts/e2e/splits-two-device.sh` runs both. Which device each one is, and
/// the invite B joins by, come from the coordinator at runtime, so both are
/// launched with the same defines and built once.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/io.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/splits/splits_relay.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';

import 'support/mobile_regtest_flow.dart';
import 'support/splits_coordinator.dart';

/// What a device is told when it is run by hand, without a coordinator.
const _phaseDefine = String.fromEnvironment('SPLITS_PHASE');
const _inviteDefine = String.fromEnvironment('SPLITS_INVITE');

/// What A pays, in minor units of the bill's currency (§2.1).
const _anaSpent = 9000;

/// What B pays.
const _benSpent = 3000;

/// 90.00 and 30.00 split evenly across two people leaves B owing 30.00.
const _benOwes = (_anaSpent - _benSpent) ~/ 2;

/// A device on the other end of the relay may be building a wallet, so the
/// first wait is long; the rest are short because by then it is only a sync.
const _firstWait = Duration(minutes: 6);
const _wait = Duration(minutes: 3);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('device', (tester) async {
    tolerateRenderOverflows();
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) return;
      defaultHandler?.call(details);
    };

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
    final accountUuid = account.activeAccountUuid!;

    // The same pieces `splits_entry_screen.dart` gives the controller: the
    // app's own storage, its keychain, the payout address it publishes, and
    // the relay it builds. The account's spending secret is what carries
    // its identity across a reinstall, and it is read the way the screen reads
    // it.
    List<int>? identitySecret;
    try {
      final secret = await container
          .read(accountProvider.notifier)
          .getSoftwareWalletSecretForAccount(accountUuid);
      if (secret != null) {
        identitySecret = splitsIdentitySecret(
          mnemonic: secret.mnemonic,
          passphrase: secret.bip39Passphrase,
        );
      }
    } on Object {
      identitySecret = null;
    }
    expect(
      account.activeAddress,
      isNotNull,
      reason: 'a participant with no payout address cannot be settled to',
    );

    // Beside the wallet database, exactly where the entry screen puts it.
    final directory = Directory(
      '${File(await getWalletDbPath()).parent.path}/splits',
    );
    final wallet = VizorSplitsWallet(
      accountUuid: accountUuid,
      identitySecret: identitySecret,
      sender: WalletSplitsSender(
        payToAddress: account.activeAddress,
        // §9.2's cash lane settles this bill: a transaction between two
        // simulators is a separate lane with a funded chain behind it, and
        // what is under test here is that a payment and its confirmation
        // cross the relay.
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
    final me = controller.me;

    // Which device this is, asked of the coordinator rather than compiled in.
    final phase = await claimRole(fallback: _phaseDefine);
    expect(
      const ['a', 'b'].contains(phase),
      isTrue,
      reason: 'the coordinator names device a or device b',
    );

    if (phase == 'a') {
      await _deviceA(tester, controller, me);
    } else {
      await _deviceB(tester, controller, me);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}

/// Opens the bill, puts an expense on it, and confirms the money arrived.
Future<void> _deviceA(
  WidgetTester tester,
  SplitsController controller,
  String me,
) async {
  final billId = (await controller.createBill(
    name: 'Dinner',
    currency: 'USD',
    displayName: 'Ana',
  ))!;
  await controller.syncBill(billId);
  final invite = await controller.inviteFor(billId);
  expect(
    invite,
    startsWith('splitz://join'),
    reason: '§11.1 renders an invite as a link, not a payload',
  );
  // The sequencer reads this line and starts device B with it. The invite
  // carries the bill id and the key; the log comes from the relay.
  logE2e('INVITE $invite');
  await publish('invite', invite);

  // 1 · B joins. Its participant id is the one its own key derives (§10.7),
  //     so it is read off the bill rather than guessed.
  await _syncUntil(
    tester,
    controller,
    billId,
    (view) => view.bill.participants.length == 2,
    description: 'device B to join',
    timeout: _firstWait,
  );
  final them = _billOn(
    controller,
    billId,
  ).bill.participants.map((p) => p.id).firstWhere((id) => id != me);
  logE2e('device B joined as $them');

  // 2 · The expense A covered, and the rate that makes the bill settleable.
  await controller.addExpense(
    billId: billId,
    paidBy: me,
    amountMinorUnits: _anaSpent,
    among: [me, them],
    description: 'Dinner',
  );
  await controller.setRate(
    billId: billId,
    currency: 'USD',
    minorUnitsPerZec: 3000,
    source: 'lane',
  );
  await controller.syncBill(billId);
  logE2e('put $_anaSpent on the bill, and a rate');

  // 3 · B's own expense arrives over the relay, netted against A's.
  await _syncUntil(
    tester,
    controller,
    billId,
    (view) => view.bill.expenses.any((e) => e.paidBy == them),
    description: "device B's expense",
  );
  logE2e('device B put $_benSpent on the bill');

  // 4 · B settles, and the record of it crosses the relay. A record is a
  //     claim (§10.5): nothing has moved on this bill until A says so.
  await _syncUntil(
    tester,
    controller,
    billId,
    (view) => view.bill.payments.any((p) => p.to == me),
    description: "device B's payment",
  );
  final payment = _billOn(
    controller,
    billId,
  ).bill.payments.singleWhere((p) => p.to == me);
  expect(
    payment.amount,
    _benOwes,
    reason: 'the netted bill leaves B owing $_benOwes',
  );
  expect(payment.from, them);

  // 5 · Only the payee may say a payment arrived, and this device is it.
  await controller.confirmPayment(
    billId: billId,
    paymentId: payment.id,
    method: 'recipientConfirmed',
  );
  await controller.syncBill(billId);
  logE2e('confirmed ${payment.id}');

  final end = _billOn(controller, billId);
  expect(
    end.setAside,
    isEmpty,
    reason: 'nothing either device wrote is refused',
  );
  expect(end.bill.confirmedPayments, contains(payment.id));
  expect(protocol.netBalances(end.bill)[me], 0);
  expect(protocol.netBalances(end.bill)[them], 0);
  logE2e('the bill owes nobody');
}

/// Joins the bill, puts a second expense on it, and settles what it owes.
Future<void> _deviceB(
  WidgetTester tester,
  SplitsController controller,
  String me,
) async {
  final published = await awaitValue(
    'invite',
    timeout: const Duration(minutes: 20),
    fallback: _inviteDefine,
  );
  expect(published, isNotEmpty, reason: 'device a published an invite');
  expect(
    controller.bills,
    isEmpty,
    reason: 'a fresh install holds no bill until it pulls',
  );

  final scanned = splitz.readScan(published);
  expect(scanned, isA<splitz.ScannedInvite>());
  final invite = (scanned as splitz.ScannedInvite).invite;
  final billId = invite.billId;

  await controller.acceptKey(billId, invite.key);
  expect(
    await controller.syncBill(billId),
    isNotNull,
    reason: 'the relay answered',
  );
  await controller.load();
  expect(
    controller.bills.map((b) => b.id),
    contains(billId),
    reason:
        'the relay holds the bill device A opened, and this device '
        'holds nothing it did not pull',
  );
  final pulled = _billOn(controller, billId);
  expect(
    pulled.bill.name,
    'Dinner',
    reason: 'the bill the other device opened arrived over the relay',
  );
  logE2e('pulled "${pulled.bill.name}"');

  // 1 · A join is what carries a display name and a payout address, and
  //     without one there is nobody to settle to.
  await controller.join(billId, displayName: 'Ben');
  await controller.syncBill(billId);

  // 2 · A's expense and the rate, both over the relay.
  await _syncUntil(
    tester,
    controller,
    billId,
    (view) => view.bill.expenses.isNotEmpty && view.bill.rate != null,
    description: "device A's expense and rate",
    timeout: _firstWait,
  );
  final them = _billOn(
    controller,
    billId,
  ).bill.participants.map((p) => p.id).firstWhere((id) => id != me);
  logE2e('device A put $_anaSpent on the bill');

  // 3 · This device's own expense. The bill is netted before it is priced,
  //     so what is settled is the difference and not the two gross amounts.
  await controller.addExpense(
    billId: billId,
    paidBy: me,
    amountMinorUnits: _benSpent,
    among: [me, them],
    description: 'Taxi',
  );
  await controller.syncBill(billId);

  // 4 · What this device owes, from the protocol rather than from this lane.
  final owed = (await controller.obligation(billId))!;
  expect(owed.settlements.single.to, them);
  expect(
    owed.settlements.single.amount,
    _benOwes,
    reason: '($_anaSpent - $_benSpent) / 2 = $_benOwes, netted then priced',
  );
  expect(
    owed.unpayable,
    isEmpty,
    reason: 'device A published a payout address when it joined',
  );

  // 5 · §9.2's cash lane: the money moves outside this protocol, and the only
  //     evidence it ever has is the payee's confirmation (§10.5).
  await controller.recordCash(
    billId: billId,
    to: them,
    amountMinorUnits: _benOwes,
    note: 'settled at the table',
  );
  await controller.syncBill(billId);
  logE2e('recorded $_benOwes to $them');

  // A payer is not asked to pay a debt twice, and is not told it is settled
  // either: it is in flight until the payee vouches for it.
  final claimed = (await controller.obligation(billId))!;
  expect(claimed.settlements, isEmpty);
  expect(claimed.awaiting.single.to, them);
  expect(claimed.awaiting.single.paid, _benOwes);

  // 6 · The confirmation crosses the relay, and only then does the debt clear.
  await _syncUntil(
    tester,
    controller,
    billId,
    (view) => view.bill.confirmedPayments.isNotEmpty,
    description: "device A's confirmation",
  );

  final end = _billOn(controller, billId);
  expect(
    end.setAside,
    isEmpty,
    reason: 'nothing either device wrote is refused',
  );
  expect(protocol.netBalances(end.bill)[me], 0);
  expect(protocol.netBalances(end.bill)[them], 0);
  expect(
    (await controller.obligation(billId))!.awaiting,
    isEmpty,
    reason: 'once the payee has vouched, the bill owes nobody',
  );
  logE2e('the bill owes nobody');
}

BillView _billOn(SplitsController controller, String billId) =>
    controller.bills.singleWhere((b) => b.id == billId);

/// Syncs until [done] holds of the bill, or fails saying what never arrived.
///
/// Every wait in this lane is a wait on the other device, so the loop pushes
/// as well as pulls: a device that only pulled would wait for an entry the
/// other one is waiting to be asked for.
Future<void> _syncUntil(
  WidgetTester tester,
  SplitsController controller,
  String billId,
  bool Function(BillView view) done, {
  required String description,
  Duration timeout = _wait,
}) async {
  final end = DateTime.now().add(timeout);
  var polls = 0;
  while (DateTime.now().isBefore(end)) {
    await controller.syncBill(billId);
    await controller.load();
    final view = controller.bills.where((b) => b.id == billId).firstOrNull;
    if (view != null && done(view)) return;
    await tester.pump(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(seconds: 2));
    if (++polls % 15 == 0) {
      logE2e('still waiting for $description');
    }
  }
  fail('Timed out waiting for $description.');
}
