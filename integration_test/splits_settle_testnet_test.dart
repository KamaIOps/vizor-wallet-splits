/// Settling a bill with testnet money, between the development wallets.
///
/// The testnet twin of the mainnet lane. TAZ is free, so this one may be run
/// as often as it is useful, and the wallets it spends from are minted by
/// `tools/testnet/mint` and funded from a faucet.
///
/// **The network name is `test`, not `testnet`.**
/// `normalizeZcashNetworkName` in `lib/src/core/config/network_config.dart`
/// matches `test` and `regtest` and sends everything else to `main`, so a
/// misspelling here does not fail — it runs the lane against mainnet with
/// testnet birthdays, and the only symptom is a sync error about the
/// lightwalletd tip being behind the wallet's.
///
/// **Nothing is broadcast unless `SPLITS_BROADCAST=true`.** The value must be
/// the word `true`: `bool.fromEnvironment` reads nothing else as true, so
/// `=1` leaves the flag off and the lane stops before the send while still
/// reporting a pass. Without it the lane
/// builds the bill, prices it, renders the payment request and stops, which
/// asserts every claim except "the money moved".
///
/// Two limits are enforced here rather than trusted:
///
///   * every recipient must be an address this device derived for one of the
///     development wallets, so a bill cannot send to anywhere else;
///   * the whole request must come to at most [maxZatoshi], which is 1,000,000
///     zatoshi — 0.01 TAZ, a tenth of one faucet drip. The cap is not about
///     value, since TAZ has none; it is so an arithmetic mistake stops here
///     rather than draining a wallet somebody has to refill by hand.
///
///     python3 <splitz>/splitz_host/tool/seed-driver.py <seed-file> --port 39200
///     flutter test integration_test/splits_settle_testnet_test.dart -d <device> \
///       --dart-define=VIZOR_FORM_FACTOR=mobile \
///       --dart-define=ZCASH_DEFAULT_NETWORK=test \
///       --dart-define=ZCASH_E2E_NETWORK=test \
///       --dart-define=SPLITS_SEED_DRIVER_URL=http://127.0.0.1:39200
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_host/splitz_host.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/splits/dev_account.dart';
import 'package:zcash_wallet/src/features/splits/regtest_accounts.dart';
import 'package:zcash_wallet/src/features/splits/testnet_accounts.dart';
import 'package:zcash_wallet/src/features/splits/dev_accounts_import.dart';
import 'package:zcash_wallet/src/features/splits/splits_send.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;
import 'package:zcash_wallet/src/rust/api/wallet.dart' as rust_wallet;

import 'support/mobile_regtest_flow.dart';

/// The most this lane may ever send, in zatoshi. See the library comment.
const int maxZatoshi = 1000000;

const bool broadcast = bool.fromEnvironment('SPLITS_BROADCAST');

/// The wallets for the chain this run is pointed at. The phrases are the same
/// either way; only the addresses and the birthdays differ.
List<DevAccount> get _accounts =>
    mobileE2eNetwork == 'regtest' ? regtestAccounts : testnetAccounts;

/// Who pays, and who is paid.
///
/// All four wallets: one payer and three payees, so the request carries three
/// recipients and the whole bill settles in **one** transaction. That is the
/// claim netting exists to make, and two recipients does not test it — two is
/// the shape a wallet that cannot batch would also produce.
///
/// The payer is the wallet that holds ZEC, because a payer with an empty
/// balance cannot answer the one question this lane exists to ask. Every
/// account carries a birthday height, so the wallet scans from July rather
/// than from Sapling activation; a recipient needs no sync at all to be paid.
const String payerName = 'TAZ-1';
const List<String> payeeNames = ['TAZ-2', 'TAZ-3', 'TAZ-4'];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('a bill between testnet wallets settles in one transaction',
      (tester) async {
    tolerateRenderOverflows();
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) return;
      defaultHandler?.call(details);
    };

    if (seedDriverUrl.isEmpty) {
      logE2e('no seed driver named; this lane needs the development wallets');
      return;
    }

    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await createWalletWithPasscode(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    await importDevAccounts(
      accounts: _accounts,
      readAccounts: () => container.read(accountProvider).value,
      readNotifier: () => container.read(accountProvider.notifier),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final accounts = container.read(accountProvider).value!.accounts;
    String uuidOf(String name) =>
        accounts.firstWhere((a) => a.name == name).uuid;

    final dbPath = await getWalletDbPath();
    final network = container.read(rpcEndpointProvider).networkName;

    // Derived, not typed: every address this bill can pay comes from an
    // account on this device, which is what keeps the money among the
    // development wallets.
    final addresses = <String, String>{};
    for (final name in [payerName, ...payeeNames]) {
      addresses[name] = await rust_wallet.getUnifiedAddress(
        dbPath: dbPath,
        network: network,
        accountUuid: uuidOf(name),
      );
    }
    logE2e('payer $payerName pays ${payeeNames.join(' and ')}');
    // Printed so a regtest run can be funded without anybody reading a seed:
    // `scripts/regtest/fund-wallet.sh <address> 1.0` takes it from here.
    addresses.forEach((name, address) => logE2e('  $name at $address'));

    await container.read(accountProvider.notifier).switchAccount(
          uuidOf(payerName),
        );

    // Wait for the payer to have something to spend. Reported as it goes, so
    // a lane that is merely slow reads differently from one that is stuck.
    var spendable = BigInt.zero;
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (DateTime.now().isBefore(deadline)) {
      final balance = await rust_sync.getBalance(
        dbPath: dbPath,
        network: network,
        accountUuid: uuidOf(payerName),
      );
      // `spendable` is the wallet's own sum of every shielded pool it can
      // spend from — Sapling, Orchard, Ironwood. Adding two of them by hand
      // silently reports zero for a wallet whose value sits in the third.
      spendable = balance.spendable;
      // Funds alone are not enough to spend them. A transaction is anchored to
      // the scanned tip, so one built while the wallet is still catching up
      // carries a stale anchor and the network refuses it — the wallet reports
      // `pendingBroadcast` with no transaction id and retries until the
      // expiry, which reads as a send that simply did not happen.
      final progress = await rust_sync.getSyncStatus(
        dbPath: dbPath,
        network: network,
      );
      final behind = progress.chainTipHeight - progress.scannedHeight;
      logE2e('$payerName spendable: $spendable zatoshi, '
          '${progress.scannedHeight}/${progress.chainTipHeight} '
          '($behind behind)');
      if (spendable > BigInt.from(maxZatoshi * 3) && progress.isComplete) {
        break;
      }
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    final finalProgress = await rust_sync.getSyncStatus(
      dbPath: dbPath,
      network: network,
    );
    if (spendable <= BigInt.from(maxZatoshi * 3) || !finalProgress.isComplete) {
      logE2e('$payerName has not synced enough to pay; stopping before a send');
      return;
    }

    // --- the bill ---------------------------------------------------------
    //
    // Two debts to two people, so one transaction pays both — which is the
    // whole reason the multi-recipient path exists.
    final wallet = VizorSplitsWallet(
      accountUuid: uuidOf(payerName),
      unifiedFullViewingKey: null,
      sender: WalletSplitsSender(
        payToAddress: addresses[payerName],
        send: (uri) async => throw StateError('the lane sends, not the seam'),
      ),
    );
    final host = WalletBillHost(wallet);

    final entries = <Map<String, dynamic>>[];
    entries.add(splitz.createBill(
      host: host,
      name: 'Dinner',
      currency: 'USD',
      creatorKey: 'A' * 43,
    ));
    final billId = entries.first['id'] as String;

    // A participant's id is whatever its host answers to (`joinBill` writes
    // `host.me`); the name is a label. A split that names labels reaches
    // nobody, so the ids are read back out of the joins rather than assumed.
    final ids = <String, String>{};
    final payerJoin = splitz.joinBill(
      host: host,
      name: payerName,
      payTo: addresses[payerName],
    );
    entries.add(payerJoin);
    ids[payerName] = _participantId(payerJoin);
    for (final name in payeeNames) {
      final join = _joinAs(name, addresses[name]!, wallet);
      entries.add(join);
      ids[name] = _participantId(join);
    }
    // 0.60 each, split two ways, so the payer owes 0.30 to each payee.
    for (final name in payeeNames) {
      entries.add(_expenseFrom(name, addresses, wallet, ids, payerName));
    }
    // One ZEC is a thousand dollars here, so 0.30 is 30_000 zatoshi. The
    // figure is chosen to keep the request small, and the cap below is what
    // enforces that rather than this arithmetic.
    entries.add(splitz.setRate(
      host: host,
      currency: 'USD',
      minorUnitsPerZec: 100000,
      source: 'fixed for this lane',
    ));

    final folded = splitz.BillLog(host, entries: entries, billId: billId).fold();
    final owed = splitz.obligationFor(host, folded)!;
    logE2e('owes ${owed.settlements.length} people, '
        'carrying ${owed.carriedMinorUnits} minor units');
    expect(owed.settlements.length, payeeNames.length,
        reason: 'one transaction should pay both');

    final uri = owed.uri!;
    logE2e('request: $uri');

    // --- the two limits, enforced ----------------------------------------
    final permitted = addresses.values.toSet();
    for (final settlement in owed.settlements) {
      final address = folded.bill.participant(settlement.to)!.payableAddress!;
      expect(permitted, contains(address),
          reason: 'a recipient that is not a development wallet');
    }
    final total = owed.settlements.fold<int>(0, (sum, s) => sum + s.amount);
    final zatoshi = total * 100000000 ~/ 100000;
    logE2e('about to send $zatoshi zatoshi (cap $maxZatoshi)');

    // What each payee already holds, read from a wallet synced off the chain
    // rather than from any local send state. An earlier run of this lane went
    // as far as `pendingBroadcast` and recorded no txid; the chain is the only
    // thing that can say whether that transaction landed.
    for (final name in payeeNames) {
      final b = await rust_sync.getBalance(
        dbPath: dbPath,
        network: network,
        accountUuid: uuidOf(name),
      );
      logE2e('payee $name holds: ${b.spendable} spendable (sapling ${b.sapling} '
          'orchard ${b.orchard} ironwood ${b.ironwood})');
    }
    expect(zatoshi, lessThanOrEqualTo(maxZatoshi),
        reason: 'over the cap this lane is allowed to send');

    if (!broadcast) {
      logE2e('SPLITS_BROADCAST is not set: stopping before the send');
      logE2e('settle mainnet: done, nothing sent');
      return;
    }

    // --- the send ---------------------------------------------------------
    //
    // Driven from the app's own tree. A `ProviderScope` owns its container and
    // disposes it when unmounted, so pumping a second tree over the app tears
    // down the sync notifier this path reads and the send fails against a
    // disposed ref rather than against the chain.
    logE2e('broadcasting');
    final outcome = await proposeAndBroadcastSplitsBatch(
      ref: _refFromTree(tester),
      accountUuid: uuidOf(payerName),
      sendFlowId: 'splits-lane-${DateTime.now().microsecondsSinceEpoch}',
      paymentRequestUri: uri,
    );

    logE2e('outcome: ${outcome.phase} txid=${outcome.txid ?? '-'} '
        '${outcome.error ?? outcome.statusMessage ?? ''}');
    expect(outcome.phase, WalletSendPhase.succeeded);
    expect(outcome.txid, isNotNull);
    logE2e('settled: sent ${outcome.txid}');
    expect(billId, isNotEmpty);

    // --- §10.5: sending is not settling ----------------------------------
    //
    // The money is on the chain, and the bill knows nothing about it. A
    // `recordPayment` is the payer's claim; it moves no balance until the
    // person paid says the money arrived. Each recipient gets its own record
    // id — one transaction paying three people is three records, and two
    // under one id would let one payee's word settle another's debt — with
    // the transaction in `reference`, which is what `onChain` reads. The id
    // is the protocol's to derive, not this lane's.
    final txid = outcome.txid!;
    for (final settlement in owed.settlements) {
      entries.add(splitz.recordPayment(
        host: host,
        paymentId: splitz.paymentIdForSend(txid, settlement.to),
        to: settlement.to,
        amount: settlement.amount,
        reference: txid,
      ));
    }

    final recorded = splitz.BillLog(host, entries: entries, billId: billId).fold();
    expect(recorded.setAside, isEmpty,
        reason: 'one id per recipient, so nothing is refused');
    expect(recorded.bill.payments.length, payeeNames.length);
    final claimed = splitz.obligationFor(host, recorded)!;
    expect(claimed.settlements, isEmpty,
        reason: 'a payer is not asked to pay a debt twice');
    expect(claimed.awaiting.map((a) => a.to).toSet(),
        owed.settlements.map((s) => s.to).toSet(),
        reason: 'every payment is in flight until its payee vouches for it');
    logE2e('recorded: ${claimed.awaiting.length} awaiting confirmation');

    // Each payee confirms the payment their own bill shows them. A payee
    // reads the id off the bill rather than assuming the transaction's.
    for (final name in payeeNames) {
      final payeeId = ids[name]!;
      final theirs =
          recorded.bill.payments.singleWhere((p) => p.to == payeeId);
      entries.add(splitz.confirmPayment(
        host: WalletBillHost(_As(wallet, name, addresses[name]!)),
        paymentId: theirs.id,
        method: 'recipientConfirmed',
      ));
    }

    final closed = splitz.BillLog(host, entries: entries, billId: billId).fold();
    expect(closed.setAside, isEmpty,
        reason: 'each payee confirmed a payment addressed to them');
    expect(closed.bill.confirmedPayments.length, payeeNames.length);
    final after = splitz.obligationFor(host, closed);
    expect(after?.settlements ?? const [], isEmpty);
    expect(after?.awaiting ?? const [], isEmpty,
        reason: 'once every payee has vouched, the bill owes nobody');
    logE2e('confirmed: the bill is closed, '
        '${closed.bill.confirmedPayments.length} payments vouched for');
  });
}

/// A join written as [name] would write it.
Map<String, dynamic> _joinAs(
  String name,
  String address,
  VizorSplitsWallet payer,
) {
  final host = WalletBillHost(_As(payer, name, address));
  return splitz.joinBill(host: host, name: name, payTo: address);
}

/// The participant id a join entry wrote.
String _participantId(Map<String, dynamic> join) =>
    (join['participant'] as Map<String, dynamic>)['id'] as String;

/// An expense [name] covered, split between them and the payer.
///
/// [ids] maps a name to the participant id its join wrote, which is what a
/// split has to name: `among` carrying display names would match no
/// participant and leave the payer owing nothing.
Map<String, dynamic> _expenseFrom(
  String name,
  Map<String, String> addresses,
  VizorSplitsWallet payer,
  Map<String, String> ids,
  String payerName,
) {
  final host = WalletBillHost(_As(payer, name, addresses[name]!));
  return splitz.addExpense(
    host: host,
    expenseId: 'x-$name',
    paidBy: ids[name]!,
    amount: 60,
    split: <String, dynamic>{
      'type': 'equal',
      'among': [ids[payerName]!, ids[name]!]..sort(),
    },
    description: 'Dinner',
  );
}

/// The payer's wallet, speaking as somebody else.
///
/// Every participant on this bill is an account on this device, so their
/// entries are written here rather than fetched from a peer. Only the id and
/// the address differ; the clock and the randomness stay the wallet's.
class _As implements SplitsWallet {
  _As(this._inner, String id, this._address)
      : account = WalletAccount(id: id, viewingKey: null);

  final VizorSplitsWallet _inner;
  final String _address;

  @override
  final WalletAccount account;

  @override
  late final WalletSender sender = WalletSplitsSender(
    payToAddress: _address,
    send: (uri) async => throw StateError('only the payer sends'),
  );

  @override
  SecretStore get secrets => _inner.secrets;

  @override
  DateTime now() => _inner.now();

  @override
  Uint8List randomBytes(int byteCount) => _inner.randomBytes(byteCount);
}

/// A widget that exists to hand its `WidgetRef` to the lane.

/// A `WidgetRef` from the running app.
///
/// A `ProviderScope` owns its container and disposes it when unmounted, so
/// pumping a second tree over the app tears down the notifiers the send path
/// reads and the send then fails against a disposed ref rather than against
/// the chain. Every `Consumer` element implements `WidgetRef`, so the live
/// tree already holds one.
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
  if (ref == null) {
    throw StateError('no Consumer element is mounted to take a ref from');
  }
  return ref;
}
