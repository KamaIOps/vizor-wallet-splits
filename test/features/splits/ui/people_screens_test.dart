/// Putting somebody on a bill, and taking them off.
///
/// §10.8 refuses to remove a participant any surviving entry still names.
/// That refusal is the feature: the fold cannot apply an entry naming
/// somebody who is not on the bill, so removing the person who spent the most
/// would otherwise drop every expense they paid for and zero the bill.
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

void main() {
  testWidgets('how each person is paid is a tag beside their name', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    await c.accept(id, [
      entries.joinBill(
        host: otherHost('ben'),
        name: 'ben',
        payouts: [
          <String, dynamic>{'type': 'cash'},
        ],
      ),
      entries.joinBill(
        host: otherHost('cai'),
        name: 'cai',
        payouts: [
          <String, dynamic>{
            'type': 'swap',
            'asset': 'USDC',
            'chain': 'base',
            'address': '0x1111111111111111111111111111111111111111',
          },
        ],
      ),
      entries.joinBill(host: otherHost('dee'), name: 'dee'),
    ]);
    expect(c.lastError, isNull);
    await t.pumpWidget(app(c, PeopleScreen(billId: id)));
    await t.pumpAndSettle();
    String? tag(String id) {
      final f = find.byKey(Key('splits_person_payout_$id'));
      return f.evaluate().isEmpty ? null : t.widget<Text>(f).data;
    }

    expect(tag('ben'), '(Cash)');
    expect(tag('cai'), '(USDC Base)');
    expect(tag('dee'), isNull, reason: 'no way to pay them, so no tag');
    expect(find.textContaining('Gets paid'), findsNothing);
  });

  group('adding somebody by hand', () {
    testWidgets('they go on the bill, unbound and honest about it', (t) async {
      final wallet = FakeWallet();
      final c = controllerFor(wallet);
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

      await t.pumpWidget(app(c, PeopleScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_people_add')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('splits_people_name')), 'Ben');
      await t.tap(find.byKey(const Key('splits_people_name_ok')));
      await t.pumpAndSettle();

      final view = c.bills.firstWhere((b) => b.id == id);
      expect(view.bill.participant('ben'), isNotNull);
      expect(view.bill.participant('ben')!.name, 'Ben');
      // No key was claimed for them, because nobody here can prove who they
      // are. §10.7 binds nothing.
      expect(view.bill.participant('ben')!.identityKey, isNull);
      expect(view.identities.bound.containsKey('ben'), isFalse);
      // Not joined from their own phone: how they are paid can be added for
      // them. Inviting is the screen's, not each row's.
      expect(find.byKey(const Key('splits_person_invite_ben')), findsNothing);
      expect(find.text('Add payment method'), findsOneWidget);
      // A later entry, as it is on a phone whose clock moves.
      wallet.tick();
      await t.tap(find.byKey(const Key('splits_person_add_payout_ben')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('splits_address_field')), 'u1ben');
      await t.tap(find.byKey(const Key('splits_address_save')));
      await t.pumpAndSettle();
      expect(c.lastError, isNull);
      final after = c.bills.firstWhere((b) => b.id == id);
      expect(after.bill.participant('ben')!.payableAddress, 'u1ben');
      expect(find.text('(ZEC)'), findsWidgets);

      // Once set, it is changed rather than added, from what it is now.
      expect(
        find.byKey(const Key('splits_person_add_payout_ben')),
        findsNothing,
      );
      wallet.tick();
      await t.tap(find.byKey(const Key('splits_person_edit_payout_ben')));
      await t.pumpAndSettle();
      expect(find.text('u1ben'), findsOneWidget);
      await t.enterText(
        find.byKey(const Key('splits_address_field')),
        'u1bennew',
      );
      await t.tap(find.byKey(const Key('splits_address_save')));
      await t.pumpAndSettle();
      expect(c.lastError, isNull);
      final changed = c.bills.firstWhere((b) => b.id == id);
      expect(changed.bill.participant('ben')!.payableAddress, 'u1bennew');
      expect(changed.redirectedAddresses.single.from, 'u1ben');
    });

    testWidgets('two people with one name get two ids', (t) async {
      // §9.1 refuses a duplicate participant, and two people called Sam are
      // ordinary.
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

      for (var i = 0; i < 2; i++) {
        await t.pumpWidget(app(c, PeopleScreen(billId: id)));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('splits_people_add')));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const Key('splits_people_name')), 'Sam');
        await t.tap(find.byKey(const Key('splits_people_name_ok')));
        await t.pumpAndSettle();
      }

      final view = c.bills.firstWhere((b) => b.id == id);
      expect(view.bill.participant('sam'), isNotNull);
      expect(view.bill.participant('sam-2'), isNotNull);
      expect(view.setAside, isEmpty);
    });

    testWidgets('a join carrying no key reads the same as a name typed here', (
      t,
    ) async {
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      // A join written on another device, but claiming no key. §10.7 binds
      // nothing, so nobody can tell it from a name typed here — and the
      // screen says the thing that is true of both.
      await c.accept(id, [
        entries.joinBill(host: otherHost('ben'), name: 'ben', payTo: 'u1ben'),
      ]);

      await t.pumpWidget(app(c, PeopleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('splits_person_ben')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('splits_person_ben')),
          matching: find.text('(ZEC)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('splits_person_ben')),
          matching: find.text('Edit payment method'),
        ),
        findsOneWidget,
      );
    });
  });

  group('taking somebody off', () {
    testWidgets('warns what the rule is before asking', (t) async {
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      await c.addPerson(billId: id, id: 'ben', name: 'Ben');

      await t.pumpWidget(app(c, PeopleScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_person_remove_ben')));
      await t.pumpAndSettle();

      expect(find.text('They’re on no expense or payment.'), findsOneWidget);
    });

    testWidgets('somebody nothing names comes off', (t) async {
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      await c.addPerson(billId: id, id: 'ben', name: 'Ben');

      await t.pumpWidget(app(c, PeopleScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_person_remove_ben')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_people_remove_confirm')));
      await t.pumpAndSettle();

      expect(
        c.bills.firstWhere((b) => b.id == id).bill.participant('ben'),
        isNull,
      );
    });

    testWidgets('somebody an expense still names does NOT come off', (t) async {
      // Without this the fold would drop every expense they paid for and
      // zero the bill — silently.
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      await c.addPerson(billId: id, id: 'ben', name: 'Ben');
      await c.addExpense(
        billId: id,
        paidBy: 'ben',
        amountMinorUnits: 9000,
        among: ['ben', c.me]..sort(),
        description: 'dinner',
      );

      await t.pumpWidget(app(c, PeopleScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_person_remove_ben')));
      await t.pumpAndSettle();
      // Said, and nothing offered: they paid, so only that expense's author
      // can take it off.
      expect(find.text('• They paid for dinner.'), findsOneWidget);
      expect(
        find.byKey(const Key('splits_people_remove_confirm')),
        findsNothing,
      );
      expect(find.byKey(const Key('splits_people_remove_all')), findsNothing);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();

      final view = c.bills.firstWhere((b) => b.id == id);
      // Still on the bill, and the expense is untouched.
      expect(view.bill.participant('ben'), isNotNull);
      expect(view.bill.expenses.single.amount, 9000);
      expect(view.setAside, isEmpty);
    });

    testWidgets('somebody who did not open the bill is offered no removal', (
      t,
    ) async {
      // §10.8 leaves withdrawing somebody else's join to the creator.
      final ana = controllerFor(FakeWallet());
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      await ana.addPerson(billId: id, id: 'cai', name: 'Cai');

      final ben = controllerFor(FakeWallet(id: 'ben', payTo: 'u1ben'));
      await ben.load();
      final scanned =
          entries.readScan((await ana.shareableBill(id))!)
              as entries.ScannedBill;
      await ben.acceptKey(id, scanned.invite!.key);
      await ben.accept(id, scanned.entries);
      await ben.join(id, displayName: 'Ben');

      await t.pumpWidget(app(ben, PeopleScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_person_cai')), findsOneWidget);
      expect(find.byKey(const Key('splits_person_remove_cai')), findsNothing);
    });

    testWidgets('this device is not offered a way to remove itself', (t) async {
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

      await t.pumpWidget(app(c, PeopleScreen(billId: id)));
      await t.pumpAndSettle();

      expect(find.byKey(Key('splits_person_remove_${c.me}')), findsNothing);
      // What it offers instead is how you are paid.
      expect(find.byKey(const Key('splits_person_payout')), findsOneWidget);
    });
  });
}
