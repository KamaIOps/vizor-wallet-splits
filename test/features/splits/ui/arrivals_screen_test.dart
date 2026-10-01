// Payments received: nothing is confirmed in one tap before today's price has
// been asked, and a price that could not be read is said (§14.2).
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/screens/arrivals_screen.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

const _tx = 'aa00000000000000000000000000000000000000000000000000000000000001';

/// A price source that answers when the test says so.
class _Held implements ZecPrices {
  final answer = Completer<int?>();

  @override
  Future<int?> minorUnitsPerZec(String currency) => answer.future;
}

/// Ana prices Dinner at 1000.00 USD a ZEC; Ben pays his 10.00 USD as 0.01 ZEC,
/// which this wallet received.
Future<(SplitsController, _Held)> _bill() async {
  final prices = _Held();
  final c = SplitsController(
    wallet: FakeWallet(),
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(5)),
    relay: const UnconfiguredSplitsRelay(),
    prices: prices,
    received: () async => const [entries.IncomingTransaction(_tx, 1000000)],
  );
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
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
        reference: _tx,
        zatoshi: 1000000,
      ),
      id,
    ),
  ]);
  expect(c.arrived, hasLength(1));
  return (c, prices);
}

Future<(SplitsController, _Held)> _open(WidgetTester t) async {
  late (SplitsController, _Held) held;
  await t.runAsync(() async => held = await _bill());
  await t.pumpWidget(
    SplitsScope(
      controller: held.$1,
      child: const MaterialApp(home: ArrivalsScreen()),
    ),
  );
  await t.pump();
  return held;
}

Future<void> _answer(
  WidgetTester t,
  _Held prices, {
  int? price,
  bool fail = false,
}) async {
  await t.runAsync(() async {
    fail
        ? prices.answer.completeError(StateError('offline'))
        : prices.answer.complete(price);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await t.pump();
}

FilledButton _confirm(WidgetTester t) =>
    t.widget<FilledButton>(find.byKey(const Key('splits_arrivals_confirm')));

void main() {
  testWidgets('the one tap waits for today\'s price', (t) async {
    final (_, prices) = await _open(t);
    expect(_confirm(t).onPressed, isNull);
    expect(find.text('Checking today\'s price…'), findsOneWidget);
    await _answer(t, prices, price: 100000);
    expect(_confirm(t).onPressed, isNotNull);
    expect(find.text('Confirm it'), findsOneWidget);
    expect(find.byKey(const Key('splits_arrivals_no_market')), findsNothing);
  });

  testWidgets('a price far from the bill\'s holds the payment back', (t) async {
    final (_, prices) = await _open(t);
    // (100000 - 120000) * 100 ~/ 120000 is -16.
    await _answer(t, prices, price: 120000);
    expect(find.byKey(const Key('splits_arrivals_confirm')), findsNothing);
    expect(find.textContaining('16% below today'), findsOneWidget);
  });

  testWidgets('a price that fails to load is said, and the tap is offered', (
    t,
  ) async {
    final (_, prices) = await _open(t);
    await _answer(t, prices, fail: true);
    expect(_confirm(t).onPressed, isNotNull);
    expect(find.byKey(const Key('splits_arrivals_no_market')), findsOneWidget);
  });

  testWidgets('a source with no price for the currency is said too', (t) async {
    final (_, prices) = await _open(t);
    await _answer(t, prices);
    expect(_confirm(t).onPressed, isNotNull);
    expect(find.byKey(const Key('splits_arrivals_no_market')), findsOneWidget);
  });

  testWidgets('once the price agrees, the one tap confirms', (t) async {
    final (c, prices) = await _open(t);
    await _answer(t, prices, price: 100000);
    await t.runAsync(() async {
      await t.tap(find.byKey(const Key('splits_arrivals_confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await t.pump();
    expect(c.bills.single.bill.confirmedPayments, hasLength(1));
  });
}
