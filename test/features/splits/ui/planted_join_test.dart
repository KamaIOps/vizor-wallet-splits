/// §10.7: a join planted under the joiner's own id, before they join.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/closing.dart';
import 'support/fake_wallet.dart';

SplitsController ctl(FakeWallet w, {int seed = 3}) => SplitsController(
  wallet: w,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(seed)),
  relay: const UnconfiguredSplitsRelay(),
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(key: UniqueKey(), home: home),
);

const victimAddr =
    'u1l8xunezsvhq8fgzfl7404m450nwnd76zshscn6nfys7vyz2ywyh4cc5daaq0c7q2su5lqf';
const attackerAddr =
    'u1ay3aawlldjrmxqnjf5medr5ma6p3acnet464ht8lmwplq5cd3ugytcmlf96rrmtgwldc75';

Future<void> run(WidgetTester t, {required bool plant}) async {
  final vic = ctl(FakeWallet(id: 'vic', payTo: victimAddr), seed: 2);
  await vic.load();
  final ana = ctl(FakeWallet(), seed: 1);
  await ana.load();
  final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
  // The victim's id is public: the same on every bill they are on.
  if (plant) {
    await ana.accept(id, [
      entries.joinBill(
        host: otherHost(vic.me, payTo: attackerAddr),
        name: 'Vic',
        payTo: attackerAddr,
      ),
    ]);
    expect(ana.lastError, isNull);
  }
  final code = (await ana.shareableBill(id))!;
  await t.pumpWidget(app(vic, ScanBillScreen(initialCode: code)));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('splits_scan_name')), 'Vic');
  await t.pump();
  await t.tap(find.byKey(const Key('splits_scan_read')));
  await t.pumpAndSettle();
  expect(find.byType(BillScreen), findsOneWidget);
  final view = vic.bills.firstWhere((b) => b.id == id);
  final mine = view.bill.participant(vic.me)!;
  final bound = view.folded!.identities.bound.containsKey(vic.me);
  // Bring the victim's entries back to the creator, as a sync would.
  final back =
      entries.readScan((await vic.shareableBill(id))!) as entries.ScannedBill;
  await ana.accept(id, back.entries);
  expect(ana.lastError, isNull);
  // Vic paid for dinner; ana owes Vic half.
  await ana.addExpense(
    billId: id,
    paidBy: vic.me,
    amountMinorUnits: 2000,
    among: [ana.me, vic.me]..sort(),
  );
  await ana.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await closeForSettling(ana, id);
  final owed = await ana.obligation(id);
  // §10.7: a planted record is not this device's join; it writes its own,
  // which binds its key and takes the record back.
  expect(mine.payTo, victimAddr);
  expect(bound, isTrue);
  expect(owed!.uri, contains(victimAddr));
  expect(owed.uri, isNot(contains(attackerAddr)));
}

void main() {
  testWidgets(
    'control: an honest join is the joiner\'s own record',
    (t) => run(t, plant: false),
  );
  testWidgets(
    'a join planted under the joiner\'s id does not stand in for theirs',
    (t) => run(t, plant: true),
  );
}
