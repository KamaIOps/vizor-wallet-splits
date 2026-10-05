// Two devices taking one person off at once leave one expense (§10.8).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController ctl(FakeWallet w, SplitsRelay relay, int seed) =>
    SplitsController(
      wallet: w,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(seed)),
      relay: relay,
    );

Future<(SplitsController, SplitsController, String)> setup() async {
  final relay = InMemorySplitsRelay();
  final ana = ctl(FakeWallet(), relay, 1);
  final ben = ctl(FakeWallet(id: 'ben', payTo: 'u1ben'), relay, 2);
  await ana.load();
  await ben.load();
  final id = (await ana.createBill(name: 'Trip', currency: 'USD'))!;
  await ana.addPerson(billId: id, id: 'cai', name: 'Cai');
  final code = (await ana.shareableBill(id))!;
  final scanned = entries.readScan(code) as entries.ScannedBill;
  await ben.acceptKey(scanned.invite!.billId, scanned.invite!.key);
  await ben.accept(id, scanned.entries);
  await ben.join(id, displayName: 'Ben');
  await ben.syncBill(id);
  await ana.syncBill(id);
  await ben.addExpense(
    billId: id,
    paidBy: ben.me,
    amountMinorUnits: 3000,
    among: [ana.me, ben.me, 'cai'],
    description: 'Taxi',
  );
  await ben.syncBill(id);
  await ana.syncBill(id);
  expect(ana.lastError, isNull);
  expect(ben.lastError, isNull);
  expect(ana.bills.single.bill.expenses, hasLength(1));
  return (ana, ben, id);
}

int total(SplitsController c) =>
    c.bills.single.bill.expenses.fold(0, (s, e) => s + e.amount);

void main() {
  test(
    'control: one device restates, the other then sees nothing to do',
    () async {
      final (ana, ben, id) = await setup();
      final plan = (await ana.removalPlan(id, 'cai'))!;
      expect(plan.complete, isTrue);
      await ana.removePerson(billId: id, id: 'cai', confirmed: plan);
      expect(ana.lastError, isNull);
      await ana.syncBill(id);
      await ben.syncBill(id);
      final benPlan = (await ben.removalPlan(id, 'cai'))!;
      expect(benPlan.edits, isEmpty);
      expect(ben.bills.single.bill.expenses, hasLength(1));
      expect(total(ben), 3000);
    },
  );

  test('both devices restate before either syncs', () async {
    final (ana, ben, id) = await setup();
    final anaPlan = (await ana.removalPlan(id, 'cai'))!;
    final benPlan = (await ben.removalPlan(id, 'cai'))!;
    await ana.removePerson(billId: id, id: 'cai', confirmed: anaPlan);
    await ben.removePerson(billId: id, id: 'cai', confirmed: benPlan);
    for (var i = 0; i < 2; i++) {
      await ana.syncBill(id);
      await ben.syncBill(id);
    }
    expect(total(ana), 3000, reason: 'one 30.00 taxi, counted once');
    expect(total(ben), 3000);
    expect(ana.bills.single.bill.participant('cai'), isNull);
  });

  test('the creator on two phones (one mnemonic) both take Cai off', () async {
    final relay = InMemorySplitsRelay();
    final phone = ctl(FakeWallet(), relay, 1);
    final tablet = ctl(FakeWallet(), relay, 7);
    await phone.load();
    await tablet.load();
    final id = (await phone.createBill(name: 'Trip', currency: 'USD'))!;
    await phone.addPerson(billId: id, id: 'cai', name: 'Cai');
    await phone.addPerson(billId: id, id: 'dee', name: 'Dee');
    await phone.addExpense(
      billId: id,
      paidBy: phone.me,
      amountMinorUnits: 3000,
      among: [phone.me, 'cai', 'dee'],
      description: 'Taxi',
    );
    final code = (await phone.shareableBill(id))!;
    final scanned = entries.readScan(code) as entries.ScannedBill;
    await tablet.acceptKey(id, scanned.invite!.key);
    await tablet.accept(id, scanned.entries);
    await phone.syncBill(id);
    await tablet.syncBill(id);
    final a = (await phone.removalPlan(id, 'cai'))!;
    final b = (await tablet.removalPlan(id, 'cai'))!;
    await phone.removePerson(billId: id, id: 'cai', confirmed: a);
    await tablet.removePerson(billId: id, id: 'cai', confirmed: b);
    for (var i = 0; i < 2; i++) {
      await phone.syncBill(id);
      await tablet.syncBill(id);
    }
    expect(total(phone), 3000, reason: 'one 30.00 taxi, counted once');
    expect(total(tablet), 3000);
    expect(phone.bills.single.bill.participant('cai'), isNull);
  });
}
