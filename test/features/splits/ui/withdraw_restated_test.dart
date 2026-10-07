// §10.8: the creator takes an expense a removal restated off the bill, and
// the person removed stays off.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

void main() {
  test('a restated expense comes off, and the guest stays off', () async {
    final wallet = FakeWallet();
    final c = SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
    );
    await c.load();
    final id = (await c.createBill(
      name: 'Trip',
      currency: 'USD',
      displayName: 'Ana',
    ))!;
    wallet.tick();
    await c.addPerson(billId: id, id: 'guest', name: 'Guest');
    wallet.tick();
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 50,
      among: [c.me, 'guest'],
      description: 'Guest snack',
    );
    wallet.tick();
    await c.removePerson(billId: id, id: 'guest');
    wallet.tick();
    expect(c.lastError, isNull);
    final snack = c.bills.single.bill.expenses.single;
    expect(snack.split.toString(), isNot(contains('guest')));

    await c.withdraw(
      billId: id,
      entryId: c.bills.single.expenseEntries[snack.id]!,
    );
    wallet.tick();
    expect(c.lastError, isNull);
    expect(c.bills.single.bill.expenses, isEmpty);
    expect(c.bills.single.bill.participant('guest'), isNull);
    expect(c.bills.single.bill.participants, hasLength(1));
    // Taken off with its first entry, the restatement goes with it: the bill
    // lists nothing as not applied.
    expect(c.bills.single.setAside, isEmpty);
  });
}
