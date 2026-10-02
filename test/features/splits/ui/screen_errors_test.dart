/// A screen shows what its own actions could not do, and nothing else.
///
/// The controller's [SplitsController.lastError] is the last failure of any
/// action. Read on open, it puts a refusal met on one bill on the bills list,
/// on a blank form and on every other bill, beside buttons that did not fail.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/screens/arrivals_screen.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController ctl({SplitsKeys? keys, FakeWallet? wallet}) =>
    SplitsController(
      wallet: wallet ?? FakeWallet(),
      store: BillStore(InMemoryBillStorage()),
      keys: keys ?? SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
    );

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(key: UniqueKey(), home: home),
);

const notOnBill = 'That person is not on this bill.';
const noRelay = 'This build has no bill relay. Share by code.';

/// Every screen that shows an action's failure, open on [id] with Ben on it.
Map<String, Widget> screensOn(String id) => {
  'BillsScreen': const BillsScreen(),
  'NewBillScreen': const NewBillScreen(),
  'BillScreen': BillScreen(billId: id),
  'PeopleScreen': PeopleScreen(billId: id),
  'PayoutScreen': PayoutScreen(billId: id),
  'PayoutForScreen': PayoutForScreen(billId: id, id: 'ben', name: 'Ben'),
  'RecordPaymentScreen': RecordPaymentScreen(billId: id, to: 'ben'),
  'ArrivalsScreen': const ArrivalsScreen(),
  'SettleScreen': SettleScreen(billId: id),
  'AddExpenseScreen': AddExpenseScreen(billId: id),
  'PriceBillScreen': PriceBillScreen(billId: id),
  'ActivityScreen': ActivityScreen(billId: id),
  'ScanBillScreen': const ScanBillScreen(),
};

/// A secret store that cannot be read, as a keychain that will not open.
class _Unreadable implements SecretStore {
  @override
  Future<String?> read(String key) async => throw StateError('locked');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('locked');
  @override
  Future<void> delete(String key) async => throw StateError('locked');
}

/// A controller whose confirmations are refused, as the controller refuses
/// one for somebody not on the bill.
class _RefusesConfirm extends SplitsController {
  _RefusesConfirm()
    : super(
        wallet: FakeWallet(),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      );

  @override
  Future<void> confirmPayment({
    required String billId,
    required String paymentId,
    required String method,
    String? reference,
  }) => setPayoutFor(
    billId: billId,
    id: 'nobody',
    payout: const protocol.Payout(type: 'cash'),
  );
}

void main() {
  testWidgets('a refusal on one bill is not on the list, a new bill, or '
      'another bill', (t) async {
    final c = ctl();
    await c.load();
    final dinner = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final lunch = (await c.createBill(name: 'Lunch', currency: 'USD'))!;
    await c.syncBill(dinner);
    // The refusal happened.
    expect(c.lastError, noRelay);

    for (final home in <Widget>[
      const BillsScreen(),
      const NewBillScreen(),
      BillScreen(billId: lunch),
    ]) {
      await t.pumpWidget(app(c, home));
      await t.pumpAndSettle();
      expect(find.text(noRelay), findsNothing, reason: '${home.runtimeType}');
    }
    c.stopPolling();
  });

  testWidgets('a refusal from an earlier action is on no screen opened '
      'after it', (t) async {
    final c = ctl();
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    await c.addPerson(billId: id, id: 'ben', name: 'Ben');
    await c.setPayoutFor(
      billId: id,
      id: 'nobody',
      payout: const protocol.Payout(type: 'cash'),
    );
    expect(c.lastError, notOnBill);

    for (final MapEntry(:key, :value) in screensOn(id).entries) {
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(app(c, value));
      await t.pumpAndSettle();
      expect(find.text(notOnBill), findsNothing, reason: key);
    }
    c.stopPolling();
  });

  testWidgets('a refusal met on a screen is shown there, and not on the next '
      'one', (t) async {
    final c = ctl();
    await c.load();
    final dinner = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final lunch = (await c.createBill(name: 'Lunch', currency: 'USD'))!;

    await t.pumpWidget(app(c, BillScreen(billId: dinner)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_bill_menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_bill_sync_now')));
    await t.pumpAndSettle();
    expect(find.text(noRelay), findsOneWidget);

    await t.pumpWidget(app(c, BillScreen(billId: lunch)));
    await t.pumpAndSettle();
    expect(find.text(noRelay), findsNothing);
    c.stopPolling();
  });

  testWidgets('the bills list says what loading them could not do', (t) async {
    final c = ctl(
      wallet: FakeWallet(identitySecret: null),
      keys: SplitsKeys(store: _Unreadable(), random: Random(3)),
    );
    await c.load();
    expect(c.loadError, isNotNull);

    await t.pumpWidget(app(c, const BillsScreen()));
    await t.pumpAndSettle();
    expect(find.text(c.loadError!), findsOneWidget);
  });

  testWidgets('a confirmation that could not be written says so on the '
      'activity screen', (t) async {
    final c = _RefusesConfirm();
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final ben = await SignedPeer.named('ben');
    await c.accept(id, [
      await ben.join(id, name: 'Ben', payTo: 'u1benpayable0000000001'),
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
          method: 'cash',
        ),
        id,
      ),
    ]);
    final pid = c.bills.single.bill.payments.single.id;

    await t.pumpWidget(app(c, ActivityScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_activity_error')), findsNothing);
    await t.tap(find.byKey(Key('splits_confirm_arrived_$pid')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('splits_confirm_sure_$pid')));
    await t.pumpAndSettle();

    expect(
      t.widget<Text>(find.byKey(const Key('splits_activity_error'))).data,
      notOnBill,
    );
    expect(c.bills.single.bill.confirmedPayments, isEmpty);
  });

  group('failureOf', () {
    test(
      'keeps its own action\'s refusal when another succeeds meanwhile',
      () async {
        final c = ctl();
        await c.load();
        final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
        final gate = Completer<void>();
        final mine = c.failureOf(() async {
          await c.setPayoutFor(
            billId: id,
            id: 'nobody',
            payout: const protocol.Payout(type: 'cash'),
          );
          await gate.future;
        });
        await pumpEventQueue();
        await c.addPerson(billId: id, id: 'ben', name: 'Ben');
        expect(c.lastError, isNull);
        gate.complete();
        expect(await mine, notOnBill);
      },
    );

    test('is not handed another action\'s refusal', () async {
      final c = ctl();
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      final gate = Completer<void>();
      final mine = c.failureOf(() async {
        await c.addPerson(billId: id, id: 'ben', name: 'Ben');
        await gate.future;
      });
      await pumpEventQueue();
      await c.syncBill(id);
      expect(c.lastError, noRelay);
      gate.complete();
      expect(await mine, isNull);
    });

    test('reads as lastError does for its own actions', () async {
      final c = ctl();
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      // A refusal, then a success: the success is the outcome.
      expect(
        await c.failureOf(() async {
          await c.syncBill(id);
          await c.addPerson(billId: id, id: 'ben', name: 'Ben');
        }),
        isNull,
      );
      expect(await c.failureOf(() => c.syncBill(id)), noRelay);
    });
  });
}
