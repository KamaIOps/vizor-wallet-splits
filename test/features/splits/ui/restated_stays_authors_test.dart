// §10.4, §10.8: an expense the creator restated while merging somebody stays
// its first author's to correct and to take off.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController _device(FakeWallet wallet, BillStorage storage, int seed) =>
    SplitsController(
      wallet: wallet,
      store: BillStore(storage),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(seed)),
      relay: const UnconfiguredSplitsRelay(),
    );

/// Ana's bill with Josh added by hand; Bo joined from his own phone and wrote
/// a dinner Josh paid, shared with Ana; Ana then merged Josh into Bo. Both
/// devices hold the whole log.
Future<(SplitsController, SplitsController, String)> _merged() async {
  final anaStore = InMemoryBillStorage();
  final boStore = InMemoryBillStorage();
  final anaWallet = FakeWallet();
  final boWallet = FakeWallet(id: 'bo', payTo: 'u1bopayable00000000001');
  final ana = _device(anaWallet, anaStore, 1);
  final bo = _device(boWallet, boStore, 2);
  await ana.load();
  await bo.load();
  final id = (await ana.createBill(name: 'Trip', currency: 'USD'))!;
  await ana.addPerson(billId: id, id: 'josh', name: 'Josh');
  Future<void> sync(BillStorage from, SplitsController to) async =>
      to.accept(id, await BillStore(from).read(id));
  await bo.acceptKey(id, await ana.billKey(id));
  await sync(anaStore, bo);
  boWallet.tick();
  await bo.join(id, displayName: 'Bo');
  boWallet.tick();
  await bo.addExpense(
    billId: id,
    paidBy: 'josh',
    amountMinorUnits: 3000,
    among: [ana.me, 'josh'],
    description: 'Dinner',
  );
  expect(bo.lastError, isNull);
  await sync(boStore, ana);
  anaWallet.tick(const Duration(hours: 1));
  final plan = (await ana.removalPlan(id, 'josh', into: bo.me))!;
  await ana.removePerson(billId: id, id: 'josh', confirmed: plan, into: bo.me);
  expect(ana.lastError, isNull);
  await sync(anaStore, bo);
  expect(bo.bills.single.bill.participant('josh'), isNull);
  return (ana, bo, id);
}

void main() {
  test('Bo may still correct the dinner, and the correction stands', () async {
    final (_, bo, id) = await _merged();
    final view = bo.bills.single;
    final dinner = view.bill.expenses.single;
    expect(view.mayCorrect(dinner.id, bo.me), isTrue);
    await bo.editExpense(
      billId: id,
      entryId: view.expenseEntries[dinner.id]!,
      amountMinorUnits: 2800,
    );
    expect(bo.lastError, isNull);
    expect(bo.bills.single.setAside, isEmpty);
    expect(bo.bills.single.bill.expenses.single.amount, 2800);
  });

  test('Bo takes the dinner off, and Josh stays off', () async {
    final (_, bo, id) = await _merged();
    final view = bo.bills.single;
    final dinner = view.bill.expenses.single;
    await bo.withdraw(billId: id, entryId: view.expenseEntries[dinner.id]!);
    expect(bo.lastError, isNull);
    expect(bo.bills.single.bill.expenses, isEmpty);
    expect(bo.bills.single.bill.participant('josh'), isNull);
    // Ana's restatement replaced the entry Bo withdrew, and goes with it
    // (§10.8): nothing is listed as not applied.
    expect(bo.bills.single.setAside, isEmpty);
  });

  test('somebody else on the bill may not correct it', () async {
    final (ana, bo, _) = await _merged();
    final dinner = bo.bills.single.bill.expenses.single;
    expect(bo.bills.single.mayCorrect(dinner.id, 'cai'), isFalse);
    // Ana wrote the restatement, so she may too.
    expect(bo.bills.single.mayCorrect(dinner.id, ana.me), isTrue);
  });
}
