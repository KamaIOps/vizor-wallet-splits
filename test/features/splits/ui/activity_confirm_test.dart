// The Activity screen's "It arrived" and "It did not arrive" against what the
// Payments received screen knows (§14.2, §14.7).
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/screens/arrivals_screen.dart'
    show disputedConcern;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

const _benTx =
    'aa00000000000000000000000000000000000000000000000000000000000001';
const _caraTx =
    'cc00000000000000000000000000000000000000000000000000000000000002';
const _neverTx =
    'ee00000000000000000000000000000000000000000000000000000000000009';

/// What this wallet received.
final List<entries.IncomingTransaction> _inbox = [];

SplitsController _controller() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
  received: () async => List.of(_inbox),
);

Future<void> _open(WidgetTester t, SplitsController c, String id) async {
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(home: ActivityScreen(billId: id)),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.runAsync(() async {
    await t.tap(f);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await t.pumpAndSettle();
}

/// Dinner, 30.00 USD this device paid, split with Ben and Cara; 1 ZEC is
/// 1000.00 USD. Ben records 10.00 USD as 0.01 ZEC in [_benTx]; Cara records
/// 10.00 USD as 0.01 ZEC naming [caraRef].
Future<(String, String, String)> _threeWay(
  SplitsController c,
  String caraRef, {
  int caraZatoshi = 1000000,
}) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  final ben = await SignedPeer.named('ben');
  final cara = await SignedPeer.named('cara');
  await c.accept(id, [
    await ben.join(id, name: 'Ben', payTo: 'u1benpayable0000000001'),
    await cara.join(id, name: 'Cara', payTo: 'u1carapayable000000001'),
  ]);
  final among = [ben.id, cara.id, c.me]..sort();
  await c.accept(id, [
    await ben.sign(
      entries.addExpense(
        host: ben.host,
        expenseId: 'x1',
        paidBy: c.me,
        amount: 3000,
        split: <String, dynamic>{'type': 'equal', 'among': among},
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
    await cara.sign(
      entries.recordPayment(
        host: cara.host,
        paymentId: 'p2',
        to: c.me,
        amount: 1000,
        reference: caraRef,
        zatoshi: caraZatoshi,
      ),
      id,
    ),
  ]);
  final payments = c.bills.single.bill.payments;
  return (
    id,
    payments.singleWhere((p) => p.from == ben.id).id,
    payments.singleWhere((p) => p.from == cara.id).id,
  );
}

/// Ben owes this device 100.00 USD and records paying it as [zatoshi] in
/// [_benTx], which this wallet received in full. [payeeRate]: this device
/// prices the bill; [benRate]: Ben does; [paidAt]: the rate Ben's record
/// states.
Future<(String, String)> _priced(
  SplitsController c, {
  int? payeeRate,
  int? benRate,
  int? paidAt,
  required int zatoshi,
}) async {
  _inbox.add(entries.IncomingTransaction(_benTx, zatoshi));
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  if (payeeRate != null) {
    await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: payeeRate);
  }
  final ben = await SignedPeer.named('ben');
  await c.accept(id, [
    await ben.join(id, name: 'Ben', payTo: 'u1benpayable0000000001'),
    await ben.sign(
      entries.addExpense(
        host: ben.host,
        expenseId: 'x1',
        paidBy: c.me,
        amount: 20000,
        split: <String, dynamic>{
          'type': 'equal',
          'among': [ben.id, c.me]..sort(),
        },
      ),
      id,
    ),
    if (benRate != null)
      await ben.sign(
        entries.setRate(
          host: ben.host,
          currency: 'USD',
          minorUnitsPerZec: benRate,
        ),
        id,
      ),
    await ben.sign(
      entries.recordPayment(
        host: ben.host,
        paymentId: 'p1',
        to: c.me,
        amount: 10000,
        reference: _benTx,
        zatoshi: zatoshi,
        paidAtRate: paidAt == null
            ? null
            : <String, dynamic>{
                'currency': 'USD',
                'minorUnitsPerZec': paidAt,
                'at': '2026-10-01T12:00:00.000Z',
              },
      ),
      id,
    ),
  ]);
  return (id, c.bills.single.bill.payments.single.id);
}

/// Taps "It arrived" on [pid] and returns the dialog's text.
Future<String> _askArrived(
  WidgetTester t,
  SplitsController c,
  String id,
  String pid,
) async {
  await _open(t, c, id);
  await _tap(t, find.byKey(Key('splits_confirm_arrived_$pid')));
  return find
      .descendant(of: find.byType(AlertDialog), matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '')
      .join('\n');
}

bool _confirmed(SplitsController c, String pid) =>
    c.bills.single.bill.confirmedPayments.contains(pid);

void main() {
  setUp(_inbox.clear);

  group('"It arrived" says what Payments received would hold back', () {
    testWidgets('a record priced off the bill\'s rate', (t) async {
      final c = _controller();
      late String id, pid;
      await t.runAsync(() async {
        (id, pid) = await _priced(
          c,
          payeeRate: 5000,
          paidAt: 1000000,
          zatoshi: 1000000,
        );
      });
      await _open(t, c, id);
      expect(
        find.byKey(Key('splits_confirm_concern_${pid}_0')),
        findsOneWidget,
      );
      final said = await _askArrived(t, c, id, pid);
      expect(said, contains('0.50 USD'));
      expect(find.byKey(Key('splits_confirm_sure_$pid')), findsNothing);
      // Confirming stays the payee's choice, once they have read why not.
      await _tap(t, find.byKey(Key('splits_confirm_anyway_sure_$pid')));
      expect(_confirmed(c, pid), isTrue);
    });

    testWidgets('a price the payer set', (t) async {
      final c = _controller();
      late String id, pid;
      await t.runAsync(() async {
        (id, pid) = await _priced(c, benRate: 100000000, zatoshi: 10000);
      });
      await _open(t, c, id);
      expect(
        find.textContaining('set this bill\'s price and is the one paying'),
        findsOneWidget,
      );
      final said = await _askArrived(t, c, id, pid);
      expect(said, contains('set this bill\'s price'));
      expect(find.byKey(Key('splits_confirm_sure_$pid')), findsNothing);
      await _tap(t, find.text('Not yet'));
      expect(_confirmed(c, pid), isFalse);
    });

    testWidgets('a transaction another payer also names', (t) async {
      _inbox.add(const entries.IncomingTransaction(_benTx, 1000000));
      final c = _controller();
      late String id, cara;
      await t.runAsync(() async {
        (id, _, cara) = await _threeWay(c, _benTx);
      });
      final said = await _askArrived(t, c, id, cara);
      expect(said, contains(disputedConcern));
      expect(find.byKey(Key('splits_confirm_sure_$cara')), findsNothing);
    });

    testWidgets('an honest record asks once, as before', (t) async {
      final c = _controller();
      late String id, pid;
      await t.runAsync(() async {
        (id, pid) = await _priced(c, payeeRate: 5000, zatoshi: 200000000);
      });
      final said = await _askArrived(t, c, id, pid);
      expect(said, contains('Check your wallet first'));
      await _tap(t, find.byKey(Key('splits_confirm_sure_$pid')));
      expect(_confirmed(c, pid), isTrue);
    });
  });

  group('"It did not arrive" is held only for a record that arrived', () {
    Future<(bool held, bool offered)> refuse(
      WidgetTester t,
      SplitsController c,
      String id,
      String pid,
    ) async {
      await _open(t, c, id);
      await _tap(t, find.byKey(Key('splits_confirm_refuse_$pid')));
      return (
        find
            .byKey(Key('splits_confirm_refuse_received_$pid'))
            .evaluate()
            .isNotEmpty,
        find
            .byKey(Key('splits_confirm_refuse_sure_$pid'))
            .evaluate()
            .isNotEmpty,
      );
    }

    testWidgets('a record copying another payer\'s transaction', (t) async {
      _inbox.add(const entries.IncomingTransaction(_benTx, 1000000));
      final c = _controller();
      late String id, cara;
      await t.runAsync(() async {
        (id, _, cara) = await _threeWay(c, _benTx);
      });
      final (held, offered) = await refuse(t, c, id, cara);
      expect((held, offered), (false, true));
      expect(find.textContaining('another payer names it too'), findsOneWidget);
      await _tap(t, find.byKey(Key('splits_confirm_refuse_sure_$cara')));
      expect(c.bills.single.bill.payments.where((p) => p.id == cara), isEmpty);
    });

    testWidgets('a record whose transaction brought less than it states', (
      t,
    ) async {
      _inbox
        ..add(const entries.IncomingTransaction(_benTx, 1000000))
        ..add(const entries.IncomingTransaction(_caraTx, 1000));
      final c = _controller();
      late String id, cara;
      await t.runAsync(() async {
        (id, _, cara) = await _threeWay(c, _caraTx);
      });
      expect(await refuse(t, c, id, cara), (false, true));
    });

    testWidgets('a record its transaction covers is held', (t) async {
      _inbox.add(const entries.IncomingTransaction(_benTx, 1000000));
      final c = _controller();
      late String id, ben;
      await t.runAsync(() async {
        (id, ben, _) = await _threeWay(c, _neverTx);
      });
      expect(c.arrived.map((a) => a.payment.id), [ben]);
      expect(await refuse(t, c, id, ben), (true, false));
    });

    testWidgets('a record naming a transaction never seen', (t) async {
      _inbox.add(const entries.IncomingTransaction(_benTx, 1000000));
      final c = _controller();
      late String id, cara;
      await t.runAsync(() async {
        (id, _, cara) = await _threeWay(c, _neverTx);
      });
      expect(await refuse(t, c, id, cara), (false, true));
      expect(find.textContaining('has not seen it yet'), findsOneWidget);
    });
  });

  group('a ZEC figure no transaction carries is shown, not thrown', () {
    test('every count has a label', () {
      expect(formatZec(0), '0 ZEC');
      expect(formatZec(1), '0.00000001 ZEC');
      expect(formatZec(2100000000000000), '21000000 ZEC');
      expect(formatZec(2100000000000001), 'more ZEC than exists');
      expect(formatZec(-1), 'a negative amount of ZEC');
    });

    for (final (label, zatoshi, shown) in [
      ('more than exists', 2100000000000001, 'more ZEC than exists'),
    ]) {
      testWidgets('a record stating $label can still be withdrawn', (t) async {
        final c = _controller();
        late String id, cara;
        await t.runAsync(() async {
          (id, _, cara) = await _threeWay(c, _neverTx, caraZatoshi: zatoshi);
        });
        await _open(t, c, id);
        expect(t.takeException(), isNull);
        expect(
          t.widget<Text>(find.byKey(Key('splits_confirm_zec_$cara'))).data,
          shown,
        );
        await _tap(t, find.byKey(Key('splits_confirm_refuse_$cara')));
        await _tap(t, find.byKey(Key('splits_confirm_refuse_sure_$cara')));
        expect(
          c.bills.single.bill.payments.where((p) => p.id == cara),
          isEmpty,
        );
      });
    }
  });
}
