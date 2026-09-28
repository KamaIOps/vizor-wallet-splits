/// Where a bill's sync stands, said in every state.
///
/// Including the two that are not failures: a build with no relay, and a bill
/// that has not synced yet. A sync indicator that never resolves reads as
/// broken, and a bill that travels by code is not broken.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// A relay that fails every call, as an unreachable one does.
class DownRelay implements SplitsRelay {
  @override
  Future<void> push(String channel, List<String> blobs) async =>
      throw const SplitsRelayException(
        'the relay is unreachable',
        isTransient: true,
      );

  @override
  Future<List<String>> fetch(String channel) async =>
      throw const SplitsRelayException(
        'the relay is unreachable',
        isTransient: true,
      );
}

/// [seed] is the key generator's, and two devices that share one mint the
/// same bill key — which is exactly what a test about a WRONG key must not
/// do. Every controller in one test that must differ gets its own.
SplitsController controllerFor(
  FakeWallet wallet, {
  SplitsRelay? relay,
  int seed = 3,
}) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(seed)),
  relay: relay ?? const UnconfiguredSplitsRelay(),
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

void main() {
  testWidgets('a build with no relay says so, and does not call it a failure', (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();

    expect(find.textContaining('travels by code'), findsOneWidget);
    expect(c.syncStateOf(id).phase, SplitsSyncPhase.noRelay);
    expect(c.hasRelay, isFalse);
  });

  testWidgets('an explicit sync with no relay answers rather than doing '
      'nothing quietly', (t) async {
    // An action that quietly did nothing looks exactly like one that worked.
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

    expect(await c.syncBill(id), isNull);
    expect(c.lastError, contains('no bill relay'));
    // And it is still not called a failure: nothing failed.
    expect(c.syncStateOf(id).phase, SplitsSyncPhase.noRelay);
  });

  testWidgets('a relay that cannot be reached is a state, not a lost bill', (
    t,
  ) async {
    final c = controllerFor(FakeWallet(), relay: DownRelay());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 9000,
      among: [c.me],
    );

    await c.syncBill(id);

    expect(c.syncStateOf(id).phase, SplitsSyncPhase.failed);
    // Everything on it is already on this device. What failed is telling the
    // others.
    expect(c.bills.firstWhere((b) => b.id == id).bill.expenses, hasLength(1));

    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.textContaining('Could not reach the others'), findsOneWidget);
  });

  testWidgets('a sync that got through reports what it actually brought', (
    t,
  ) async {
    // Measured, not reported: a sync returns the whole merged log rather than
    // what it added, so a figure from the relay would be one nothing backs.
    final relay = InMemorySplitsRelay();
    final maker = controllerFor(
      FakeWallet(id: 'ben', payTo: 'u1ben'),
      relay: relay,
    );
    await maker.load();
    final id = (await maker.createBill(name: 'Dinner', currency: 'USD'))!;
    await maker.addExpense(
      billId: id,
      paidBy: maker.me,
      amountMinorUnits: 9000,
      among: [maker.me],
    );
    await maker.syncBill(id);

    // A second device with the bill's key, holding nothing.
    final joiner = controllerFor(FakeWallet(), relay: relay);
    await joiner.load();
    await joiner.acceptKey(id, await maker.billKey(id));
    await joiner.syncBill(id);

    final state = joiner.syncStateOf(id);
    expect(state.phase, SplitsSyncPhase.synced);
    expect(state.received, greaterThan(0));
    expect(state.unopenable, 0);
  });

  testWidgets('blobs that will not open are counted, not ignored', (t) async {
    // A channel where every blob is unopenable is a key that is wrong, and
    // that looks identical to a quiet relay unless it is said.
    final relay = InMemorySplitsRelay();
    final maker = controllerFor(
      FakeWallet(id: 'ben', payTo: 'u1ben'),
      relay: relay,
    );
    await maker.load();
    final id = (await maker.createBill(name: 'Dinner', currency: 'USD'))!;
    await maker.syncBill(id);

    // A device holding the same bill id under a different key.
    final stranger = controllerFor(FakeWallet(), relay: relay);
    await stranger.load();
    // A different key generator, or it would mint the same key and the blobs
    // would open perfectly.
    final other = controllerFor(FakeWallet(id: 'cara'), relay: relay, seed: 99);
    await other.load();
    final decoyId = (await other.createBill(name: 'Other', currency: 'USD'))!;
    await stranger.acceptKey(id, await other.billKey(decoyId));
    await stranger.syncBill(id);

    expect(stranger.syncStateOf(id).unopenable, greaterThan(0));
  });

  testWidgets('the poll stops when the bill screen closes', (t) async {
    // A poll running behind a closed screen spends a person's battery on a
    // bill nobody is looking at.
    final relay = InMemorySplitsRelay();
    final c = controllerFor(FakeWallet(), relay: relay);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    // Replacing the tree disposes the screen.
    await t.pumpWidget(app(c, const BillsScreen()));
    await t.pumpAndSettle();

    // Nothing pending: a live periodic timer fails the test binding.
    expect(find.byType(BillScreen), findsNothing);
  });
}
