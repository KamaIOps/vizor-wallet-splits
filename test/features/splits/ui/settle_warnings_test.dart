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
    testWidgets('is shown even once they take cash and no request pays them', (
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

      // §14.2: every replaced address the fold recorded is put in front of
      // the payer, whether or not this request pays them.
      expect(
        find.byKey(const Key('splits_settle_replaced_ben')),
        findsOneWidget,
      );
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

    testWidgets('is one short line that stays closed until the address '
        'changes again', (t) async {
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
      final card = find.byKey(const Key('splits_settle_replaced_ben'));
      expect(card, findsOneWidget);
      await t.tap(find.byKey(const Key('splits_settle_replaced_close_ben')));
      await t.pumpAndSettle();
      expect(card, findsNothing);

      // Closed on this device: the screen opened again does not show it.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(card, findsNothing);

      // A later change is a different address, and is shown again.
      await c.accept(id, [
        entries.joinBill(
          host: otherHost('ben'),
          name: 'ben',
          payTo: 'u1benthirdaddress0000003',
        ),
      ]);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(card, findsOneWidget);
    });

    testWidgets('closes from the bill screen too, and stays closed on both', (
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

      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      final card = find.byKey(const Key('splits_bill_replaced_ben'));
      expect(card, findsOneWidget);
      await t.tap(find.byKey(const Key('splits_bill_replaced_close_ben')));
      await t.pumpAndSettle();
      expect(card, findsNothing);

      // The bill screen opened again, and Settle up, both keep it closed.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(card, findsNothing);
      await t.pumpWidget(app(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_settle_replaced_ben')), findsNothing);

      // A later change is shown again on the bill screen.
      await c.accept(id, [
        entries.joinBill(
          host: otherHost('ben'),
          name: 'ben',
          payTo: 'u1benthirdaddress0000003',
        ),
      ]);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(card, findsOneWidget);
    });

    testWidgets('closed on Settle up, it is gone on the bill on the way back', (
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

      // §14.9: Settle up opens once the bill is closed.
      await c.closeForSettling(id);
      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      final onBill = find.byKey(const Key('splits_bill_replaced_ben'));
      expect(onBill, findsOneWidget);
      await t.tap(find.byKey(const Key('splits_bill_settle')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_settle_replaced_close_ben')));
      await t.pumpAndSettle();
      await t.pageBack();
      await t.pumpAndSettle();
      expect(onBill, findsNothing);
    });

    testWidgets('a first address, where there was none, shows no card on the '
        'bill', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c);
      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_bill_replaced_ben')), findsNothing);
    });

    testWidgets('a switch to cash shows no card on the bill', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c);
      await c.accept(id, [
        entries.joinBill(
          host: WalletBillHost(FakeWallet(id: 'ben', payTo: null)..tick()),
          name: 'ben',
          payouts: const [
            <String, dynamic>{'type': 'cash'},
          ],
        ),
      ]);
      expect(c.bills.single.replacedAddresses, isNotEmpty);
      expect(c.bills.single.redirectedAddresses, isEmpty);

      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_bill_replaced_ben')), findsNothing);
    });

    testWidgets('an address, then cash, then another address is shown', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c);
      await c.accept(id, [
        entries.joinBill(
          host: WalletBillHost(FakeWallet(id: 'ben', payTo: null)..tick()),
          name: 'ben',
          payouts: const [
            <String, dynamic>{'type': 'cash'},
          ],
        ),
      ]);
      await c.accept(id, [
        entries.joinBill(
          host: WalletBillHost(
            FakeWallet(id: 'ben', payTo: 'u1bensomewhereelse000002')
              ..tick()
              ..tick(),
          ),
          name: 'ben',
          payTo: 'u1bensomewhereelse000002',
        ),
      ]);
      expect(
        c.bills.single.redirectedAddresses.single.to,
        'u1bensomewhereelse000002',
      );

      await t.pumpWidget(app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_bill_replaced_ben')), findsOneWidget);
    });

    testWidgets('back to the address they had is not a redirect', (t) async {
      final c = controllerFor(FakeWallet());
      final id = await owingBen(c);
      await c.accept(id, [
        entries.joinBill(
          host: WalletBillHost(FakeWallet(id: 'ben', payTo: null)..tick()),
          name: 'ben',
          payouts: const [
            <String, dynamic>{'type': 'cash'},
          ],
        ),
      ]);
      await c.accept(id, [
        entries.joinBill(
          host: WalletBillHost(
            FakeWallet(id: 'ben', payTo: 'u1benoriginaladdress0001')
              ..tick()
              ..tick(),
          ),
          name: 'ben',
          payTo: 'u1benoriginaladdress0001',
        ),
      ]);
      expect(c.bills.single.redirectedAddresses, isEmpty);
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

    testWidgets('a change for somebody this request does not pay is shown '
        'too', (t) async {
      // §14.2 asks for every replaced address, not only those this request
      // pays: the payer is told before deciding anything.
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
        findsOneWidget,
      );
    });
  });
}
