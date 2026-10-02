/// The app killed while a payment request is being sent, and relaunched.
///
/// A settle writes a note of the send before it hands the request to the
/// wallet (§14.3), so a process that dies part-way leaves that note behind.
/// This proves, on a regtest chain, what the relaunched app does with it:
///
///   SPLITS_PHASE=send    fund this wallet, open a bill owing the payee 10.00,
///                        log KILLPOINT and start the send; the runner kills
///                        the app the moment it sees that line
///   SPLITS_PHASE=resume  the same install, relaunched: the unresolved send is
///                        found, a second send is refused, and it is resolved
///                        from what the wallet's own history shows
///
/// Whichever instant the kill landed at, the payee is paid exactly once and
/// the bill holds exactly one record of it. The runner checks the first of
/// those against the node.
///
/// `scripts/e2e/splits-kill-resume.sh` runs both phases.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import 'support/mobile_regtest_flow.dart';

const _phase = String.fromEnvironment('SPLITS_PHASE');
const _payee = String.fromEnvironment('SPLITS_PAYEE_ADDRESS');

/// What the payee covered, split two ways: this device owes half, 10.00.
const _spent = 2000;
const _owed = 1000;

/// One ZEC is 1000.00 here, so 10.00 is 1_000_000 zatoshi.
const _minorUnitsPerZec = 100000;
const _owedZatoshi = 1000000;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeZcashWalletRuntime();
  });

  testWidgets('a send the app was killed in the middle of', (tester) async {
    tolerateRenderOverflows();
    final defaultHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is SocketException) return;
      defaultHandler?.call(details);
    };
    expect(const ['send', 'resume'].contains(_phase), isTrue);
    expect(_payee, isNotEmpty, reason: 'SPLITS_PAYEE_ADDRESS');

    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    if (_phase == 'send') {
      await createWalletWithPasscode(tester);
    } else {
      await _unlock(tester);
    }
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    final account = container.read(accountProvider).value!;
    final uuid = account.activeAccountUuid!;

    if (_phase == 'send') {
      logE2e('ADDRESS ${account.activeAddress}');
      await _waitSpendable(tester, container, uuid, 3 * _owedZatoshi);
    }

    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/splits');
    await pumpUntil(
      tester,
      () => tester.any(find.byType(BillsScreen)),
      description: 'the bills screen',
      timeout: const Duration(minutes: 2),
    );
    final c = SplitsScope.read(tester.element(find.byType(BillsScreen)));
    await c.load();

    if (_phase == 'send') {
      await _send(tester, c);
    } else {
      await _resume(tester, c, container, uuid);
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}

Future<void> _send(WidgetTester tester, SplitsController c) async {
  final id = (await c.createBill(name: 'Killed', currency: 'USD'))!;
  final ben = WalletBillHost(_Peer('ben'));
  await c.accept(id, [
    splitz.joinBill(host: ben, name: 'Ben', payTo: _payee),
    splitz.addExpense(
      host: ben,
      expenseId: 'dinner',
      paidBy: 'ben',
      amount: _spent,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['ben', c.me]..sort(),
      },
    ),
  ]);
  await c.setRate(
    billId: id,
    currency: 'USD',
    minorUnitsPerZec: _minorUnitsPerZec,
  );
  final owed = (await c.obligation(id))!;
  expect(owed.settlements.single.amount, _owed);
  expect(owed.carriedZatoshi, {'ben': _owedZatoshi});
  logE2e('KILLPOINT ${DateTime.now().toIso8601String()}');
  final settled = await c.settle(id, owed);
  // Reached only when the send finished before the kill landed.
  logE2e(
    'SETTLED ${DateTime.now().toIso8601String()} '
    '${settled?.result} ${settled?.txid}',
  );
  for (var i = 0; i < 600; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _resume(
  WidgetTester tester,
  SplitsController c,
  ProviderContainer container,
  String uuid,
) async {
  final id = c.bills.single.id;
  await _dumpWallet(container, uuid, 'on relaunch');
  final note = await c.pendingSend(id);
  logE2e(
    'PENDING ${note == null ? 'none' : 'txid=${note.txid}'} '
    'records=${c.bills.single.bill.payments.length}',
  );

  if (note != null) {
    // 1 · Nothing goes out a second time while the first is unresolved.
    final again = await c.failureOf(() async {
      final owed = await c.obligation(id);
      if (owed != null) await c.settle(id, owed);
    });
    logE2e('second send while unresolved: $again');
    expect(again, isNotNull, reason: 'a second send was not refused');

    // 2 · Resolved from the wallet's own history, once the chain has it.
    final sent = await _sentToPayee(tester, container, uuid);
    if (sent == null) {
      // Nothing left the wallet: the note is cleared and the debt is sent.
      await _ok(c, () => c.resolveSend(id));
      // Blocks were mined while the history was read; the wallet spends only
      // once it has scanned them, as a person resending would wait for.
      await _waitSpendable(tester, container, uuid, 2 * _owedZatoshi);
      await _dumpWallet(container, uuid, 'before resend');
      final owed = (await c.obligation(id))!;
      final settled = await c.settle(id, owed);
      logE2e(
        'RESEND ${settled?.result} txid=${settled?.txid} '
        'detail=${settled?.detail} lastError=${c.lastError}',
      );
      await _dumpWallet(container, uuid, 'after resend');
      expect(settled?.result, splitz.SendResult.sent);
      logE2e('BRANCH killed-before-broadcast; sent again ${settled?.txid}');
    } else {
      // It did leave: saying it did not is refused, and recording it is not.
      final denied = await c.failureOf(() => c.resolveSend(id));
      logE2e('claim nothing was sent: $denied');
      expect(denied, isNotNull, reason: 'the wallet holds this send');
      await _ok(c, () => c.resolveSend(id, landed: true, txid: sent));
      logE2e('BRANCH killed-after-broadcast; recorded $sent');
    }
  } else {
    logE2e('BRANCH send-finished-before-kill');
  }

  // 3 · Exactly one record, and nothing more to pay.
  await c.load();
  final view = c.bills.single;
  final toBen = view.bill.payments.where((p) => p.to == 'ben').toList();
  expect(toBen, hasLength(1), reason: 'one payment record, not two');
  expect(toBen.single.amount, _owed);
  expect(await c.pendingSend(id), isNull);
  final after = (await c.obligation(id))!;
  expect(after.settlements.where((s) => s.to == 'ben'), isEmpty);
  logE2e('DONE one record of ${toBen.single.amount}');
}

/// The txid of this wallet's send to the payee since the bill was opened,
/// once mined, or null when the wallet shows none.
///
/// Waits for the chain: a broadcast the kill interrupted may still be
/// relayed, and an unmined one may yet expire.
Future<String?> _sentToPayee(
  WidgetTester tester,
  ProviderContainer container,
  String uuid,
) async {
  final dbPath = await getWalletDbPath();
  final network = container.read(rpcEndpointProvider).networkName;
  final end = DateTime.now().add(const Duration(minutes: 3));
  while (DateTime.now().isBefore(end)) {
    final history = await rust_sync.getTransactionHistory(
      dbPath: dbPath,
      network: network,
      accountUuid: uuid,
    );
    final sends = [
      for (final t in history)
        if (t.accountBalanceDelta <= -_owedZatoshi) t,
    ];
    logE2e(
      'history: ${sends.length} send(s) '
      '${[for (final t in sends) '${t.txidHex.substring(0, 8)}@${t.minedHeight}']}',
    );
    final mined = sends.where((t) => t.minedHeight > BigInt.zero);
    if (mined.isNotEmpty) return mined.first.txidHex;
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  return null;
}

/// Logs the wallet's balances and its whole transaction history.
Future<void> _dumpWallet(
  ProviderContainer container,
  String uuid,
  String label,
) async {
  final dbPath = await getWalletDbPath();
  final network = container.read(rpcEndpointProvider).networkName;
  final b = await rust_sync.getBalance(
    dbPath: dbPath,
    network: network,
    accountUuid: uuid,
  );
  final st = await rust_sync.getSyncStatus(dbPath: dbPath, network: network);
  logE2e(
    'WALLET $label: scanned=${st.scannedHeight} tip=${st.chainTipHeight} '
    'syncing=${st.isSyncing} complete=${st.isComplete} '
    'spendable=${b.spendable} total=${b.total} '
    'locked=${b.locked} orchardLocked=${b.orchardLocked} '
    'saplingLocked=${b.saplingLocked} '
    'orchardPending=${b.orchardPending} saplingPending=${b.saplingPending} '
    'changePending=${b.changePendingConfirmation} '
    'valuePendingSpendability=${b.valuePendingSpendability} '
    'orchard=${b.orchard} sapling=${b.sapling} '
    'availability=${b.availability}',
  );
  final history = await rust_sync.getTransactionHistory(
    dbPath: dbPath,
    network: network,
    accountUuid: uuid,
  );
  logE2e('WALLET $label: ${history.length} tx');
  for (final t in history) {
    logE2e(
      'WALLET tx ${t.txidHex.substring(0, 8)} mined=${t.minedHeight} '
      'expiredUnmined=${t.expiredUnmined} delta=${t.accountBalanceDelta} '
      'created=${t.createdTime} kind=${t.txKind}',
    );
  }
}

Future<void> _ok(SplitsController c, Future<void> Function() action) async {
  final failure = await c.failureOf(action);
  expect(failure, isNull, reason: failure);
}

Future<void> _unlock(WidgetTester tester) async {
  await pumpUntil(
    tester,
    () => tester.any(find.bySemanticsLabel('Digit 1')),
    description: 'the unlock keypad',
    timeout: const Duration(minutes: 2),
  );
  await enterPasscode(tester, mobileE2ePasscode);
  await waitForHome(tester);
}

Future<void> _waitSpendable(
  WidgetTester tester,
  ProviderContainer container,
  String uuid,
  int needed,
) async {
  final dbPath = await getWalletDbPath();
  final network = container.read(rpcEndpointProvider).networkName;
  final end = DateTime.now().add(const Duration(minutes: 15));
  while (DateTime.now().isBefore(end)) {
    final b = await rust_sync.getBalance(
      dbPath: dbPath,
      network: network,
      accountUuid: uuid,
    );
    final s = await rust_sync.getSyncStatus(dbPath: dbPath, network: network);
    if (s.isComplete && b.spendable >= BigInt.from(needed)) {
      logE2e('funded: ${b.spendable} spendable');
      return;
    }
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  fail('never had $needed zatoshi spendable');
}

/// Ben, written into the bill by this device: unsigned, as a person added by
/// name is (§10.7).
class _Peer implements SplitsWallet {
  _Peer(String id) : account = WalletAccount(id: id);

  @override
  final WalletAccount account;

  @override
  late final WalletSender sender = WalletSplitsSender(
    payToAddress: _payee,
    send: (uri) async => throw StateError('ben does not send'),
  );

  @override
  final SecretStore secrets = InMemorySecretStore();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  Uint8List randomBytes(int n) => Uint8List(n);
}
