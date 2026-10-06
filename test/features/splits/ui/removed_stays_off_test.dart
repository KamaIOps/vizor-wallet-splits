// §10.8: somebody taken off the bill still holds its key. An entry they write
// afterwards naming themselves never puts them back on it.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

Future<(SplitsController, String)> _setUp({required bool benWrites}) async {
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
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 5000);
  await c.accept(id, [
    entries.joinBill(host: otherHost('ben'), name: 'Ben', payTo: 'u1ben'),
  ]);
  wallet.tick();
  final plan = (await c.removalPlan(id, 'ben'))!;
  await c.removePerson(billId: id, id: 'ben', confirmed: plan);
  if (benWrites) {
    final ben = WalletBillHost(
      FakeWallet(id: 'ben')..tick(const Duration(hours: 1)),
    );
    await c.accept(id, [
      entries.addExpense(
        host: ben,
        expenseId: 'x1',
        paidBy: 'ben',
        amount: 9000,
        description: 'Taxi',
        split: <String, dynamic>{
          'type': 'equal',
          'among': ['ben', c.me]..sort(),
        },
      ),
    ]);
  }
  return (c, id);
}

void main() {
  for (final benWrites in [false, true]) {
    testWidgets(
      benWrites
          ? 'an expense the removed person writes is set aside, not owed'
          : 'control: removed, and writes nothing',
      (t) async {
        late (SplitsController, String) s;
        await t.runAsync(() async => s = await _setUp(benWrites: benWrites));
        final (c, id) = s;
        expect(c.bills.single.bill.participant('ben'), isNull);
        late dynamic owed;
        await t.runAsync(() async => owed = await c.obligation(id));
        expect(owed?.settlements ?? const [], isEmpty);
        await t.pumpWidget(
          SplitsScope(
            controller: c,
            child: MaterialApp(home: ActivityScreen(billId: id)),
          ),
        );
        await t.pumpAndSettle();
        expect(
          find.textContaining("That person isn't on this bill."),
          benWrites ? findsOneWidget : findsNothing,
        );
      },
    );
  }
}
