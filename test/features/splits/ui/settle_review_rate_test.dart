// The payer's review shows the rate the request was priced at while a sync
// has merged a new rate and not yet published it.
//
// The window is held open by storage that answers its next read of the bill
// only when told.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/widgets/review_list_row.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// Storage that, once armed, holds the first read of a bill after that
/// bill's next write.
class HeldAfterWrite implements BillStorage {
  final InMemoryBillStorage inner = InMemoryBillStorage();
  bool armed = false;
  bool _pending = false;
  Completer<void>? gate;
  final Completer<void> reached = Completer<void>();

  @override
  Future<String?> read(String key) async {
    final v = await inner.read(key);
    if (_pending && key.startsWith('splitz_bill_')) {
      _pending = false;
      gate = Completer<void>();
      reached.complete();
      await gate!.future;
    }
    return v;
  }

  @override
  Future<void> write(String key, String value) async {
    await inner.write(key, value);
    if (armed && key.startsWith('splitz_bill_')) {
      armed = false;
      _pending = true;
    }
  }

  @override
  Future<void> delete(String key) => inner.delete(key);
  @override
  Future<List<String>> keys(String prefix) => inner.keys(prefix);
  @override
  Future<int> sweepUnfinishedWrites() async => 0;
}

/// A live feed answering a fixed USD price, running [during] once while it
/// is asked.
class FixedPrices implements ZecPrices {
  FixedPrices(this.usd);
  final int usd;
  Future<void> Function()? during;
  @override
  Future<int?> minorUnitsPerZec(String currency) async {
    final hook = during;
    during = null;
    if (hook != null) await hook();
    return currency == 'USD' ? usd : null;
  }
}

String? textOf(WidgetTester t, String key) {
  final f = find.descendant(
    of: find.byKey(const Key('splits_review')),
    matching: find.byKey(Key(key)),
  );
  if (f.evaluate().isEmpty) return null;
  final w = t.widget(f);
  return w is Text
      ? w.data
      : w is ReviewListRow
      ? w.value
      : w.toString();
}

typedef Rig = (
  SplitsController ana,
  SplitsController ben,
  FakeWallet anaWallet,
  FakeWallet benWallet,
  HeldAfterWrite storage,
  FixedPrices prices,
  String id,
);

/// Ben makes the bill and pays 20.00 USD for two; Ana owes him 10.00 and
/// prices the bill at 50.00 USD a ZEC. Ana's settle screen is open.
Future<Rig> open(WidgetTester t) async {
  final prices = FixedPrices(5000);
  final relay = InMemorySplitsRelay();
  final storage = HeldAfterWrite();
  final anaWallet = FakeWallet();
  final benWallet = FakeWallet(id: 'ben', payTo: 'u1benpayable0000000001');
  final ana = SplitsController(
    wallet: anaWallet,
    store: BillStore(storage),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(1)),
    relay: relay,
    prices: prices,
  );
  final ben = SplitsController(
    wallet: benWallet,
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(2)),
    relay: relay,
  );
  await ana.load();
  await ben.load();
  final id = (await ben.createBill(name: 'Dinner', currency: 'USD'))!;
  await ana.acceptKey(id, await ben.billKey(id));
  await ben.syncBill(id);
  await ana.syncBill(id);
  await ana.join(id, displayName: 'Ana');
  await ana.syncBill(id);
  await ben.syncBill(id);
  benWallet.tick();
  await ben.addExpense(
    billId: id,
    paidBy: ben.me,
    amountMinorUnits: 2000,
    among: [ana.me, ben.me],
    description: 'Dinner',
  );
  await ben.syncBill(id);
  await ana.syncBill(id);
  anaWallet.tick(const Duration(minutes: 2));
  await ana.setRate(
    billId: id,
    currency: 'USD',
    minorUnitsPerZec: 5000,
    source: 'feed',
  );
  await ana.syncBill(id);
  await ben.syncBill(id);
  expect(ana.lastError, isNull);
  expect(ben.lastError, isNull);
  expect(ana.bills.single.bill.rate?.minorUnitsPerZec, 5000);

  await t.pumpWidget(
    SplitsScope(
      controller: ana,
      child: MaterialApp(home: SettleScreen(billId: id)),
    ),
  );
  await t.pumpAndSettle();
  return (ana, ben, anaWallet, benWallet, storage, prices, id);
}

/// Ben, the creator and the creditor, sets 25.00 USD a ZEC, which decides
/// (§7): Ana now owes 0.4 ZEC.
Future<void> benHalvesTheRate(Rig r) async {
  final (_, ben, _, benWallet, _, _, id) = r;
  benWallet.tick(const Duration(minutes: 5));
  await ben.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 2500);
  await ben.syncBill(id);
  expect(ben.lastError, isNull);
}

/// Taps Pay until the review opens, at most twice.
Future<bool> tapPay(WidgetTester t) async {
  for (var i = 0; i < 2; i++) {
    await t.tap(find.byKey(const Key('splits_settle_send')));
    await t.pump();
    await t.pump();
    await t.pumpAndSettle();
    if (find.byKey(const Key('splits_review')).evaluate().isNotEmpty) {
      return true;
    }
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
  }
  return false;
}

/// What the review shows beside 0.4 ZEC: the rate it was priced at, and that
/// it is far under the market (§14.2).
void expectReviewOfHalvedRate(WidgetTester t) {
  expect(
    find.descendant(
      of: find.byKey(const Key('splits_review_payment_0')),
      matching: find.text('0.4 ZEC'),
    ),
    findsOneWidget,
  );
  expect(textOf(t, 'splits_settle_rate'), contains('25.00'));
  expect(textOf(t, 'splits_review_rate_off'), isNotNull);
  expect(textOf(t, 'splits_review_setter_paid'), isNull);
}

void main() {
  testWidgets('a sync published before the tap', (t) async {
    final r = await open(t);
    await benHalvesTheRate(r);
    await r.$1.syncBill(r.$7);
    await t.pumpAndSettle();
    expect(await tapPay(t), isTrue);
    expectReviewOfHalvedRate(t);
  });

  testWidgets('a sync merged and not yet published when the payer taps', (
    t,
  ) async {
    final r = await open(t);
    final (ana, _, anaWallet, _, storage, _, id) = r;
    await benHalvesTheRate(r);
    storage.armed = true;
    final syncing = ana.syncBill(id);
    await t.pump();
    await storage.reached.future;
    await t.pump();
    expect(ana.bills.single.bill.rate?.minorUnitsPerZec, 5000);

    expect(await tapPay(t), isTrue);
    expectReviewOfHalvedRate(t);
    await t.ensureVisible(find.byKey(const Key('splits_review_send')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_review_send')));
    await t.pumpAndSettle();
    expect(anaWallet.sender.sent.single, contains('amount=0.4'));

    storage.gate!.complete();
    await syncing;
    await t.pumpAndSettle();
  });

  testWidgets('a rate that moves after the pricing opens no review', (t) async {
    final r = await open(t);
    final (ana, _, anaWallet, _, _, prices, id) = r;
    prices.during = () async {
      await benHalvesTheRate(r);
      await ana.syncBill(id);
    };
    await t.tap(find.byKey(const Key('splits_settle_send')));
    await t.pump();
    await t.pump();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_review')), findsNothing);
    expect(find.textContaining('The bill changed'), findsOneWidget);
    expect(anaWallet.sender.sent, isEmpty);
  });
}
