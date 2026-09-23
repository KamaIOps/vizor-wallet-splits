/// One bill, four devices, and §9.2's three payout lanes at once.
///
/// The payer owes three people who want to be paid three different ways: one
/// in shielded ZEC, one in USDC on Base, one in cash. §8.5 puts only the first
/// in the payment request and reports the other two rather than flattening
/// them, so a single transaction settles one debt and the other two are
/// settled outside the chain and vouched for by the people who were paid.
///
/// **The ZEC leg is a real transaction on a regtest chain.** It goes through
/// the library's own `settle`, which is what decides the records a send may
/// write — one per recipient, each with its own id, the transaction in
/// `reference`.
///
/// Each device runs once, keeps its install for the whole run, and learns
/// everything about the others by syncing the bill. The payer's address is
/// printed so the sequencer can fund it before the bill is opened.
///
///     python3 <splitz>/tools/relay/server.py --port 39300
///     flutter test integration_test/splits_lanes_test.dart -d <A> \
///       --dart-define=SPLITS_PHASE=payer \
///       --dart-define=SPLITS_RELAY_URL=http://127.0.0.1:39300
///
/// `scripts/e2e/splits-lanes.sh` runs all four and carries the invite and the
/// funding across.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/io.dart';
import 'package:splitz_flutter/splitz_flutter.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/splits/splits_relay.dart';
import 'package:zcash_wallet/src/features/splits/splits_send.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import 'support/mobile_regtest_flow.dart';
import 'support/splits_coordinator.dart';

/// What a device is told when it is run by hand, without a coordinator.
const _phaseDefine = String.fromEnvironment('SPLITS_PHASE');
const _inviteDefine = String.fromEnvironment('SPLITS_INVITE');

/// What each payee covered, in minor units of USD. Split two ways, so the
/// payer owes each of them half.
const _spent = 6000;
const _owedEach = _spent ~/ 2;

/// One ZEC is 1000.00 here, so 30.00 is 3_000_000 zatoshi — small enough that
/// an arithmetic mistake cannot drain the faucet wallet.
const _minorUnitsPerZec = 100000;
const _maxZatoshi = 20000000;

// Every device runs the same binary and they start together, so a wait here
// is a wait on the relay and on a wallet being created — not on three more
// builds. The first is longer because a device may still be installing.
const _firstWait = Duration(minutes: 10);
const _wait = Duration(minutes: 8);

/// The payee lanes, by phase name: what each one wants and how it is settled.
const _lanes = {
  'zec': 'shieldedZec',
  'usdc': 'swap',
  'cash': 'cash',
};

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

    // Which device this is, asked of the coordinator rather than compiled in.
    final phase = await claimRole(fallback: _phaseDefine);
    expect(
      const ['payer', 'zec', 'usdc', 'cash'].contains(phase),
      isTrue,
      reason: 'the coordinator names the payer or one of the three lanes, '
          'and gave "$phase"',
    );
    logE2e('this device is the $phase');
    expect(splitsRelayUrl, isNotEmpty, reason: 'this lane needs a relay');

    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await createWalletWithPasscode(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    final account = container.read(accountProvider).value!;
    final accountUuid = account.activeAccountUuid!;
    final address = account.activeAddress;
    expect(address, isNotNull,
        reason: 'a participant with no address cannot be paid in ZEC');

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

    // The sequencer funds the payer's address before the bill is opened. Only
    // the payer needs coins; the others need an address to be paid at. It is
    // published rather than printed, so nothing has to scrape a log for it.
    if (phase == 'payer') await publish('address', address!);
    logE2e('ADDRESS $address');

    final directory = Directory(
      '${File(await getWalletDbPath()).parent.path}/splits',
    );
    final wallet = VizorSplitsWallet(
      accountUuid: accountUuid,
      identitySecret: identitySecret,
      sender: WalletSplitsSender(
        payToAddress: address,
        // The app's own send, so the ZEC leg is a transaction this chain
        // accepts rather than a stub that returns an id.
        send: (uri) => proposeAndBroadcastSplitsBatch(
          ref: _refFromTree(tester),
          accountUuid: accountUuid,
          sendFlowId: 'splits-lanes-${DateTime.now().microsecondsSinceEpoch}',
          paymentRequestUri: uri,
        ),
      ),
    );
    final controller = SplitsController(
      wallet: wallet,
      store: BillStore(FileBillStorage(directory)),
      keys: SplitsKeys(store: wallet.secrets),
      relay: splitsRelay(),
    );
    await controller.load();

    if (phase == 'payer') {
      await _payer(tester, controller, container, accountUuid);
    } else {
      await _payee(tester, controller, phase, address!);
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}

/// Opens the bill, settles all three lanes, and waits to be vouched for.
Future<void> _payer(
  WidgetTester tester,
  SplitsController controller,
  ProviderContainer container,
  String accountUuid,
) async {
  final me = controller.me;
  final network = container.read(rpcEndpointProvider).networkName;
  final dbPath = await getWalletDbPath();

  // The faucet paid this address before the bill was opened. Spendable
  // matters, not received: an unconfirmed note cannot be sent on.
  await _pumpUntilAsync(
    tester,
    () async {
      final b = await rust_sync.getBalance(
        dbPath: dbPath,
        network: network,
        accountUuid: accountUuid,
      );
      return b.spendable > BigInt.from(_maxZatoshi);
    },
    description: 'the faucet payment to arrive and confirm',
    timeout: _firstWait,
  );
  logE2e('funded');

  final billId = (await controller.createBill(
    name: 'Dinner',
    currency: 'USD',
    displayName: 'Ana',
  ))!;
  await controller.setRate(
    billId: billId,
    currency: 'USD',
    minorUnitsPerZec: _minorUnitsPerZec,
    source: 'fixed for this lane',
  );
  await controller.syncBill(billId);
  final invite = await controller.inviteFor(billId);
  await publish('invite', invite);
  logE2e('INVITE $invite');

  // 1 · All three join, declare their lane, and put what they covered on the
  //     bill. Each is waited for rather than assumed.
  await _syncUntil(
    tester,
    controller,
    billId,
    (view) =>
        view.bill.participants.length == 4 && view.bill.expenses.length == 3,
    description: 'three payees to join and spend',
    timeout: _firstWait,
  );
  final bill = _billOn(controller, billId).bill;
  final lane = <String, String>{};
  for (final p in bill.participants) {
    if (p.id == me) continue;
    final payouts = p.payouts;
    expect(payouts, isNotEmpty, reason: '${p.name} declared no lane');
    lane[p.id] = payouts.first.type;
  }
  expect(lane.values.toSet(), {'zec', 'swap', 'cash'},
      reason: 'one payee in each of §9.2\'s three lanes');
  logE2e('lanes: $lane');

  // 2 · §8.5 carries the ZEC payee and reports the other two. A request that
  //     quietly dropped them would claim a debt was settled that was not.
  final owed = (await controller.obligation(billId))!;
  // `settlements` is everything this device owes; `unpayable` is the subset
  // §8.5 could not put in the request. They overlap — `settle` subtracts one
  // from the other before it records anything — so the payable set is the
  // difference rather than the whole of either.
  expect(owed.settlements.length, 3, reason: 'one debt to each payee');
  expect(owed.settlements.every((s) => s.amount == _owedEach), isTrue);
  expect(
    {for (final u in owed.unpayable) lane[u.id]: u.reason},
    {'swap': 'payout_not_zec', 'cash': 'payout_not_zec'},
    reason: 'left out for a reason that is not a missing address, and said so',
  );
  final withheld = {for (final u in owed.unpayable) u.id};
  final carried =
      owed.settlements.where((s) => !withheld.contains(s.to)).toList();
  expect(carried.single.amount, _owedEach);
  expect(lane[carried.single.to], 'zec',
      reason: 'only a Zcash address can go in a ZIP 321 request');
  expect(owed.isComplete, isFalse,
      reason: 'the request does not carry the whole obligation');
  final zatoshi = _owedEach * 100000000 ~/ _minorUnitsPerZec;
  expect(zatoshi, lessThanOrEqualTo(_maxZatoshi));
  logE2e('request carries $zatoshi zatoshi; 2 payees withheld');

  // 3 · The ZEC lane, on the chain, through the library's own settle.
  final settled = await controller.settle(billId, owed);
  expect(settled!.result, splitz.SendResult.sent,
      reason: 'detail: ${settled.detail}');
  final txid = settled.txid!;
  expect(settled.records.length, 1,
      reason: 'a record for what the transaction carried, and nothing else');
  expect(settled.records.single['payment']['id'],
      splitz.paymentIdForSend(txid, carried.single.to),
      reason: 'a record carries its own id; the transaction is the reference');
  expect(settled.records.single['payment']['reference'], txid);
  logE2e('sent $txid');

  // 4 · The other two lanes. Neither is a transaction on this chain, and
  //     neither settles anything until the person paid says it arrived.
  final swapTo = lane.entries.firstWhere((e) => e.value == 'swap').key;
  final cashTo = lane.entries.firstWhere((e) => e.value == 'cash').key;
  await controller.recordSwap(
    billId: billId,
    reference: 'near-intent-${DateTime.now().millisecondsSinceEpoch}',
    to: swapTo,
    amountMinorUnits: _owedEach,
    zatoshi: zatoshi,
    note: 'USDC on base',
  );
  await controller.recordCash(
    billId: billId,
    to: cashTo,
    amountMinorUnits: _owedEach,
    note: 'handed over at the table',
  );
  await controller.syncBill(billId);

  final claimed = (await controller.obligation(billId))!;
  expect(claimed.settlements, isEmpty,
      reason: 'a payer is not asked to pay a debt twice');
  expect(claimed.awaiting.map((a) => a.to).toSet(), lane.keys.toSet(),
      reason: 'all three are in flight until their payee vouches');
  logE2e('recorded 3 payments, ${claimed.awaiting.length} awaiting');

  // 5 · Each payee vouches for the record addressed to them, and only then
  //     does the bill owe nobody.
  await _syncUntil(
    tester,
    controller,
    billId,
    (view) => view.bill.confirmedPayments.length == 3,
    description: 'three confirmations',
  );
  final end = _billOn(controller, billId);
  expect(end.setAside, isEmpty,
      reason: 'nothing any of the four devices wrote is refused');
  final balances = protocol.netBalances(end.bill);
  for (final p in end.bill.participants) {
    expect(balances[p.id], 0, reason: '${p.name} is square');
  }
  expect((await controller.obligation(billId))!.awaiting, isEmpty);
  logE2e('the bill owes nobody: zec on chain, usdc by swap, cash by hand');
}

/// Joins in one lane, spends on the bill, and vouches for what arrives.
Future<void> _payee(
  WidgetTester tester,
  SplitsController controller,
  String phase,
  String address,
) async {
  // The payer publishes the invite once the bill is on the relay; until then
  // there is nothing to join.
  final invite0 =
      await awaitValue('invite',
          timeout: const Duration(minutes: 20), fallback: _inviteDefine);
  expect(invite0, isNotEmpty, reason: 'the payer published an invite');
  final scanned = splitz.readScan(invite0);
  final invite = (scanned as splitz.ScannedInvite).invite;
  final billId = invite.billId;

  await controller.acceptKey(billId, invite.key);
  expect(await controller.syncBill(billId), isNotNull);
  await controller.load();
  expect(controller.bills.map((b) => b.id), contains(billId),
      reason: 'the relay holds the bill the payer opened');

  // 1 · The lane this device is in. §9.2 keeps the order, so the first
  //     preference is the one that decides.
  final payout = switch (phase) {
    'zec' => splitz.Payout(type: 'zec', address: address),
    'usdc' => const splitz.Payout(
        type: 'swap', asset: 'USDC', chain: 'base', address: '0xcara'),
    _ => const splitz.Payout(type: 'cash'),
  };
  await controller.setPayouts(
    billId: billId,
    payouts: [payout],
    displayName: phase,
  );
  await controller.syncBill(billId);
  logE2e('joined in the ${payout.type} lane');

  // 2 · Everybody waits for the payer's rate before spending, so the bill is
  //     priced once and the three expenses net against one number.
  await _syncUntil(
    tester,
    controller,
    billId,
    (view) => view.bill.rate != null,
    description: "the payer's rate",
    timeout: _firstWait,
  );
  final me = controller.me;
  final them = _billOn(controller, billId)
      .bill
      .participants
      .map((p) => p.id)
      .firstWhere((id) => id != me && id == _creatorOf(controller, billId));
  await controller.addExpense(
    billId: billId,
    paidBy: me,
    amountMinorUnits: _spent,
    among: [me, them],
    description: 'Round paid by $phase',
  );
  await controller.syncBill(billId);
  logE2e('put $_spent on the bill');

  // 3 · The record addressed to this device, in the method its lane uses.
  await _syncUntil(
    tester,
    controller,
    billId,
    (view) => view.bill.payments.any((p) => p.to == me),
    description: 'the payment addressed to this device',
  );
  final payment =
      _billOn(controller, billId).bill.payments.singleWhere((p) => p.to == me);
  expect(payment.amount, _owedEach);
  expect(payment.method, _lanes[phase],
      reason: 'each lane is settled by the method §9.2 gives it');
  if (phase == 'zec') {
    expect(payment.reference, isNotNull,
        reason: 'a shielded payment names the transaction it rode on');
  }

  // 4 · §10.5: only the payee may say the money arrived. `walletReceived` is
  //     the wallet seeing it land, which only the ZEC lane can claim.
  final method = phase == 'zec' ? 'walletReceived' : 'recipientConfirmed';
  await controller.confirmPayment(
    billId: billId,
    paymentId: payment.id,
    method: method,
  );
  await controller.syncBill(billId);
  logE2e('confirmed ${payment.id} as $method');

  await _syncUntil(
    tester,
    controller,
    billId,
    (view) => view.bill.confirmedPayments.length == 3,
    description: 'the other two confirmations',
  );
  final end = _billOn(controller, billId);
  expect(end.setAside, isEmpty);
  expect(protocol.netBalances(end.bill)[me], 0);
  logE2e('the bill owes nobody');
}

String _creatorOf(SplitsController controller, String billId) =>
    _billOn(controller, billId).creatorId;

BillView _billOn(SplitsController controller, String billId) =>
    controller.bills.singleWhere((b) => b.id == billId);

Future<void> _syncUntil(
  WidgetTester tester,
  SplitsController controller,
  String billId,
  bool Function(BillView view) done, {
  required String description,
  Duration timeout = _wait,
}) async {
  await _pumpUntilAsync(
    tester,
    () async {
      await controller.syncBill(billId);
      await controller.load();
      final view = controller.bills.where((b) => b.id == billId).firstOrNull;
      return view != null && done(view);
    },
    description: description,
    timeout: timeout,
  );
}

/// Pumps until [done] answers true, or fails saying what never happened.
Future<void> _pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() done, {
  required String description,
  Duration timeout = _wait,
}) async {
  final end = DateTime.now().add(timeout);
  var polls = 0;
  while (DateTime.now().isBefore(end)) {
    if (await done()) return;
    await tester.pump(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(seconds: 2));
    if (++polls % 15 == 0) {
      logE2e('still waiting for $description');
    }
  }
  fail('Timed out waiting for $description.');
}

/// The app's own `WidgetRef`, which the send path reads its providers from.
///
/// Pumping a second tree over the app would dispose the container this reads,
/// and the send would then fail against a disposed ref rather than the chain.
WidgetRef _refFromTree(WidgetTester tester) {
  WidgetRef? found;
  void visit(Element element) {
    if (found != null) return;
    if (element is WidgetRef) {
      found = element as WidgetRef;
      return;
    }
    element.visitChildren(visit);
  }

  tester.binding.rootElement!.visitChildren(visit);
  final ref = found;
  if (ref == null) throw StateError('no WidgetRef in the app tree');
  return ref;
}
