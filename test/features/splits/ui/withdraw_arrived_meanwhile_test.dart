// §14.7: a payee never withdraws a record its wallet shows arrived, including
// when the transaction arrives while the withdrawal dialog is open.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

const _benTx =
    'aa00000000000000000000000000000000000000000000000000000000000001';

final List<entries.IncomingTransaction> _inbox = [];

SplitsController _controller() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
  received: () async => List.of(_inbox),
);

Future<(String, String)> _benPaysMe(SplitsController c) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  final ben = await SignedPeer.named('ben');
  await c.accept(id, [
    await ben.join(id, name: 'Ben', payTo: 'u1benpayable0000000001'),
  ]);
  await c.accept(id, [
    await ben.sign(
      entries.addExpense(
        host: ben.host,
        expenseId: 'x1',
        paidBy: c.me,
        amount: 2000,
        split: <String, dynamic>{
          'type': 'equal',
          'among': [ben.id, c.me]..sort(),
        },
      ),
      id,
    ),
    await ben.sign(
      entries.recordPayment(
        host: ben.host,
        paymentId: 'p1',
        to: c.me,
        amount: 1000,
        reference: _benTx,
        zatoshi: 1000000,
      ),
      id,
    ),
  ]);
  return (id, c.bills.single.bill.payments.single.id);
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.runAsync(() async {
    await t.tap(f);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await t.pumpAndSettle();
}

void main() {
  setUp(_inbox.clear);

  testWidgets('control: arrived before the tap -> held, not offered', (
    t,
  ) async {
    _inbox.add(const entries.IncomingTransaction(_benTx, 1000000));
    final c = _controller();
    late String id, pid;
    await t.runAsync(() async => (id, pid) = await _benPaysMe(c));
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(home: ActivityScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();
    await _tap(t, find.byKey(Key('splits_confirm_refuse_$pid')));
    final held = find
        .byKey(Key('splits_confirm_refuse_received_$pid'))
        .evaluate()
        .isNotEmpty;
    final offered = find
        .byKey(Key('splits_confirm_refuse_sure_$pid'))
        .evaluate()
        .isNotEmpty;
    expect((held, offered), (true, false));
  });

  testWidgets('arrives while "It did not arrive?" is open', (t) async {
    final c = _controller();
    late String id, pid;
    await t.runAsync(() async => (id, pid) = await _benPaysMe(c));
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(home: ActivityScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();
    await _tap(t, find.byKey(Key('splits_confirm_refuse_$pid')));
    expect(find.byKey(Key('splits_confirm_refuse_sure_$pid')), findsOneWidget);
    // The wallet syncs the block holding Ben's transaction; the next refresh
    // (any poll) proposes it as arrived.
    _inbox.add(const entries.IncomingTransaction(_benTx, 1000000));
    await t.runAsync(() => c.currentView(id));
    expect(
      c.arrivedCovering(id, pid),
      isNotNull,
      reason: 'the arrival landed while the dialog was open',
    );
    await _tap(t, find.byKey(Key('splits_confirm_refuse_sure_$pid')));
    final left = c.bills.single.bill.payments.where((p) => p.id == pid);
    expect(
      left,
      isNotEmpty,
      reason: 'a record the wallet shows arrived was withdrawn (§14.7)',
    );
  });
}
