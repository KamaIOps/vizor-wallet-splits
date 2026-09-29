/// What §14.2 says a payer must meet before settling.
///
/// Four things, each an answer the protocol produces and discards nowhere. A
/// request that omits one looks, to the person paying, exactly like one that
/// has nothing to omit.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

/// A priced bill where this device owes Ben, who is payable in ZEC.
Future<String> owingBen(SplitsController c) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'ben', payTo: 'u1benoriginaladdress0001'),
    entries.addExpense(
      host: ben,
      expenseId: 'x1',
      paidBy: 'ben',
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['ben', c.me]..sort(),
      },
    ),
  ]);
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  return id;
}

void main() {
  group('a replaced pay-to address', () {
    testWidgets('is not said to receive this request once they take cash', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c);

      // Ben switches to cash, later: his address goes, and no request pays
      // him.
      final later = FakeWallet(id: 'ben', payTo: null)..tick();
      final ben = WalletBillHost(later);
      await c.accept(id, [
        entries.joinBill(
          host: ben,
          name: 'ben',
          payouts: const [
            <String, dynamic>{'type': 'cash'},
          ],
        ),
      ]);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_settle_replaced_ben')), findsNothing);
      expect(
        find.byKey(const Key('splits_settle_unpayable_ben')),
        findsOneWidget,
      );
    });

    testWidgets('is put in front of the payer before they settle', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c);

      // Ben rejoins with somewhere else to be paid. This is the one change on
      // a bill that moves money to a different wallet.
      final ben = otherHost('ben');
      await c.accept(id, [
        entries.joinBill(
          host: ben,
          name: 'ben',
          payTo: 'u1bensomewhereelse000002',
        ),
      ]);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(
        find.byKey(const Key('splits_settle_replaced_ben')),
        findsOneWidget,
      );
      expect(find.textContaining('Check with them'), findsOneWidget);
    });

    testWidgets('shows both ends, because a swap changes the middle', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c);
      await c.accept(id, [
        entries.joinBill(
          host: otherHost('ben'),
          name: 'ben',
          payTo: 'u1bensomewhereelse000002',
        ),
      ]);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      // A prefix alone would make a substituted address look identical to
      // the one it replaced.
      expect(find.textContaining('u1benorigi'), findsOneWidget);
      expect(find.textContaining('u1bensomew'), findsOneWidget);
    });

    testWidgets('a bill where nothing changed shows no warning', (t) async {
      // The control: a warning that is always there is one nobody reads.
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_settle_replaced_ben')), findsNothing);
      expect(find.textContaining('Check with them'), findsNothing);
    });

    testWidgets('a change for somebody this request does not pay is not '
        'raised here', (t) async {
      // History, not a decision: the payer is settling with Ben, and a third
      // party's old address has no bearing on that.
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c);
      final cara = otherHost('cara');
      await c.accept(id, [
        entries.joinBill(
          host: cara,
          name: 'cara',
          payTo: 'u1carafirstaddress000001',
        ),
      ]);
      await c.accept(id, [
        entries.joinBill(
          host: cara,
          name: 'cara',
          payTo: 'u1carasecondaddress00002',
        ),
      ]);

      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(
        find.byKey(const Key('splits_settle_replaced_cara')),
        findsNothing,
      );
    });
  });
}
