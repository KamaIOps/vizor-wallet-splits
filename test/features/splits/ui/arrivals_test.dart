/// Payments to this device that its wallet received, confirmed from the
/// transaction; and where this device stands across bills.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

const _txid =
    'aa00000000000000000000000000000000000000000000000000000000000001';

SplitsController _controller(List<entries.IncomingTransaction> received) =>
    SplitsController(
      wallet: FakeWallet(),
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
      received: () async => received,
    );

Widget _app(SplitsController c) => SplitsScope(
  controller: c,
  child: const MaterialApp(home: BillsScreen()),
);

/// A bill named [name] where Ben owes this device 10.00 USD, and has
/// recorded paying it as [zatoshi] in [_txid].
Future<String> _benPaid(
  SplitsController c, {
  String name = 'Dinner',
  int zatoshi = 1000000,
}) async {
  final id = (await c.createBill(name: name, currency: 'USD'))!;
  // Priced, so the payee can see what the ZEC is worth: 1,000,000 zatoshi at
  // 100,000 cents a ZEC is the 10.00 USD it settles.
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benpayable0000000001'),
    entries.addExpense(
      host: ben,
      expenseId: 'x1',
      paidBy: c.me,
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['ben', c.me]..sort(),
      },
    ),
    entries.recordPayment(
      host: ben,
      paymentId: 'p1',
      to: c.me,
      amount: 1000,
      reference: _txid,
      zatoshi: zatoshi,
    ),
  ]);
  return id;
}

void main() {
  group('a payment the wallet received', () {
    test('is proposed, and confirming it settles the debt', () async {
      final c = _controller(const [
        entries.IncomingTransaction(_txid, 1000000),
      ]);
      await c.load();
      final id = await _benPaid(c);
      expect(c.lastError, isNull);
      expect(c.arrived.map((a) => a.payment.id), ['ben:p1']);

      await c.confirmArrivals(c.arrived);
      expect(c.lastError, isNull);
      final bill = c.bills.single;
      expect(bill.id, id);
      expect(bill.bill.confirmedPayments, {'ben:p1'});
      expect(c.arrived, isEmpty, reason: 'a confirmed record is not proposed');
    });

    test('a slower history read never replaces a newer one', () async {
      // The first read is held open; a second refresh runs meanwhile and
      // finds nothing. The first, when it answers, must not win.
      final held = Completer<List<entries.IncomingTransaction>>();
      var hold = false;
      final c = SplitsController(
        wallet: FakeWallet(),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        received: () {
          if (!hold) return Future.value(const []);
          hold = false;
          return held.future;
        },
      );
      await c.load();
      final id = await _benPaid(c);
      hold = true;
      final slow = c.accept(id, const []);
      await pumpEventQueue();
      await c.accept(id, const []);
      held.complete(const [entries.IncomingTransaction(_txid, 1000000)]);
      await slow;
      expect(c.arrived, isEmpty);
    });

    test('is not proposed when less arrived than the record states', () async {
      final c = _controller(const [entries.IncomingTransaction(_txid, 999999)]);
      await c.load();
      await _benPaid(c);
      expect(c.arrived, isEmpty);
    });

    test('is not proposed when the wallet history does not read', () async {
      final c = SplitsController(
        wallet: FakeWallet(),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        received: () async => throw StateError('no database'),
      );
      await c.load();
      await _benPaid(c);
      expect(c.lastError, isNull);
      expect(c.arrived, isEmpty);
    });

    testWidgets('is shown before it is confirmed, then confirmed in one tap', (
      t,
    ) async {
      final c = _controller(const [
        entries.IncomingTransaction(_txid, 1000000),
      ]);
      await t.runAsync(() async {
        await c.load();
        await _benPaid(c);
      });
      await t.pumpWidget(_app(c));
      await t.pumpAndSettle();
      expect(find.text('1 payment received'), findsOneWidget);

      await t.tap(find.byKey(const Key('splits_arrivals')));
      await t.pumpAndSettle();
      // §14.2: the ZEC the record says was sent, and the transaction.
      expect(find.textContaining('0.01 ZEC'), findsOneWidget);
      expect(find.textContaining('tx aa000000'), findsOneWidget);

      await t.runAsync(() async {
        await t.tap(find.byKey(const Key('splits_arrivals_confirm')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await t.pumpAndSettle();
      expect(c.bills.single.bill.confirmedPayments, {'ben:p1'});
      expect(find.byKey(const Key('splits_arrivals')), findsNothing);
    });
  });

  group('across bills', () {
    testWidgets('one person on two bills is one line', (t) async {
      final c = _controller(const []);
      await t.runAsync(() async {
        await c.load();
        await _benPaid(c, name: 'Dinner');
        await _benPaid(c, name: 'Lunch');
      });
      final standing = c.totals.standings.single;
      expect(standing.owedToMe, 2000);
      expect(standing.receivedAwaiting, 2000);

      await t.pumpWidget(_app(c));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_totals')), findsOneWidget);
      expect(find.textContaining('owes you 20.00 USD'), findsOneWidget);
    });

    testWidgets('one person on two rows, when two bills cannot be one sum, '
        'is two lines', (t) async {
      const most = 9223372036854775807;
      final c = _controller(const []);
      await t.runAsync(() async {
        await c.load();
        for (final name in ['Dinner', 'Lunch']) {
          final id = await _benPaid(c, name: name);
          await c.accept(id, [
            entries.recordPayment(
              host: otherHost('ben'),
              paymentId: 'p2',
              to: c.me,
              // With p1's 1000, Ben's records on the bill reach 2^63 - 1
              // exactly, which one bill holds (§10.3).
              amount: most - 1000,
            ),
          ]);
        }
      });
      expect(c.totals.uncounted, isEmpty);
      expect(c.totals.standings, hasLength(2));

      await t.pumpWidget(_app(c));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.textContaining('owes you 10.00 USD'), findsNWidgets(2));
      expect(find.byKey(const Key('splits_totals_uncounted')), findsNothing);
    });

    testWidgets('one bill shows no totals line', (t) async {
      final c = _controller(const []);
      await t.runAsync(() async {
        await c.load();
        await _benPaid(c);
      });
      await t.pumpWidget(_app(c));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_totals')), findsNothing);
    });
  });
}
