// What the bill and its history say about who changed what: an address
// change on a record anybody holding the invite can write, a withdrawal and
// what it withdrew, somebody no longer on the bill, and a screen left while
// it is still working.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController _controller(FakeWallet wallet, [BillStorage? storage]) =>
    SplitsController(
      wallet: wallet,
      store: BillStore(storage ?? InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
    );

Widget _app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

/// Every line the history shows, title and caveat.
List<String> _lines(WidgetTester t) => [
  for (final tile in t.widgetList<ListTile>(find.byType(ListTile)))
    [
      (tile.title as Text?)?.data,
      (tile.subtitle as Text?)?.data,
    ].whereType<String>().join(' | '),
];

class _SlowDelete extends InMemoryBillStorage {
  bool hold = false;
  final List<Completer<void>> waiting = [];

  @override
  Future<void> delete(String key) async {
    if (hold) {
      final gate = Completer<void>();
      waiting.add(gate);
      await gate.future;
    }
    return super.delete(key);
  }
}

void main() {
  group('an address change on a record nobody has bound', () {
    testWidgets('a peer writing it is not said to be them', (t) async {
      final c = _controller(FakeWallet());
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
        await c.addPerson(billId: id, id: 'ben', name: 'Ben');
        await c.setAddressFor(billId: id, id: 'ben', address: 'u1benreal');
        // Dee, holding the invite, writes Ben's record with her address.
        await c.accept(id, [
          entries.joinBill(host: otherHost('dee'), name: 'Dee', payTo: 'u1dee'),
          entries.joinBill(
            host: otherHost('ben', payTo: 'u1dee'),
            name: 'Ben',
            payTo: 'u1dee',
          ),
        ]);
      });
      expect(c.lastError, isNull);
      expect(c.bills.single.redirectedAddresses.single.id, 'ben');

      await t.pumpWidget(_app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.textContaining('Ben changed their address'), findsNothing);
      expect(
        find.text('Where Ben is paid changed. Check with them.'),
        findsOneWidget,
      );

      await t.pumpWidget(_app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      final lines = _lines(t);
      expect(lines.where((l) => l.contains('Ben changed where')), isEmpty);
      expect(
        lines,
        contains(
          'Where Ben is paid changed | anyone with the invite can change it '
          '— check with them before paying',
        ),
      );
    });

    testWidgets('the organiser changing it by hand is said the same way', (
      t,
    ) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
        await c.addPerson(billId: id, id: 'ben', name: 'Ben');
        wallet.tick();
        await c.setAddressFor(billId: id, id: 'ben', address: 'u1benfirst');
        wallet.tick();
        await c.setAddressFor(billId: id, id: 'ben', address: 'u1bensecond');
      });
      expect(c.lastError, isNull);
      await t.pumpWidget(_app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(
        find.text('Where Ben is paid changed. Check with them.'),
        findsOneWidget,
      );
      await t.pumpWidget(_app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      expect(
        _lines(t).where((l) => l.startsWith('Where Ben is paid changed')),
        isNotEmpty,
      );
    });

    testWidgets('a participant bound to their key is said to have done it', (
      t,
    ) async {
      final c = _controller(FakeWallet());
      late String id;
      late SignedPeer ben;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
        ben = await SignedPeer.named('ben');
        await c.accept(id, [
          await ben.join(id, name: 'Ben', payTo: 'u1benfirst'),
          await ben.join(id, name: 'Ben', payTo: 'u1bensecond'),
        ]);
      });
      expect(c.lastError, isNull);
      expect(c.bills.single.identities.bound.containsKey(ben.id), isTrue);
      expect(c.bills.single.redirectedAddresses, isNotEmpty);
      await t.pumpWidget(_app(c, BillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.text('Ben changed where they are paid.'), findsOneWidget);
      await t.pumpWidget(_app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      expect(
        _lines(t),
        contains(
          'Ben changed where they are paid | check this with them before '
          'paying',
        ),
      );
    });
  });

  group('the settle screen on an address change', () {
    /// Ben paid 20.00 USD for this device and himself; this device owes him
    /// 10.00, and the bill is priced. [rewrite] then changes his address.
    Future<String> owesBen(
      SplitsController c,
      FakeWallet wallet,
      Future<void> Function(String id) rewrite,
    ) async {
      await c.load();
      final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
      await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
      await rewrite(id);
      final ben = c.bills.single.bill.participants
          .firstWhere((p) => p.name == 'Ben')
          .id;
      wallet.tick();
      await c.addExpense(
        billId: id,
        paidBy: ben,
        amountMinorUnits: 2000,
        among: [ben, c.me],
      );
      return id;
    }

    testWidgets('a record nobody has bound is not said to be theirs', (
      t,
    ) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      await t.runAsync(() async {
        id = await owesBen(c, wallet, (id) async {
          await c.addPerson(billId: id, id: 'ben', name: 'Ben');
          await c.setAddressFor(billId: id, id: 'ben', address: 'u1benreal');
          await c.accept(id, [
            entries.joinBill(
              host: otherHost('ben', payTo: 'u1dee'),
              name: 'Ben',
              payTo: 'u1dee',
            ),
          ]);
        });
      });
      expect(c.lastError, isNull);
      expect(c.bills.single.redirectedAddresses.single.id, 'ben');

      await t.pumpWidget(_app(c, SettleScreen(billId: id)));
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pumpAndSettle();
      final card = find.byKey(const Key('splits_settle_replaced_ben'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.textContaining('Ben changed')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('Where Ben is paid changed. Check with them.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a participant bound to their key is said to have done it', (
      t,
    ) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      late SignedPeer ben;
      await t.runAsync(() async {
        ben = await SignedPeer.named('ben');
        id = await owesBen(c, wallet, (id) async {
          await c.accept(id, [
            await ben.join(id, name: 'Ben', payTo: 'u1benfirst'),
            await ben.join(id, name: 'Ben', payTo: 'u1bensecond'),
          ]);
        });
      });
      expect(c.lastError, isNull);
      expect(c.bills.single.identities.bound.containsKey(ben.id), isTrue);

      await t.pumpWidget(_app(c, SettleScreen(billId: id)));
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pumpAndSettle();
      final card = find.byKey(Key('splits_settle_replaced_${ben.id}'));
      expect(
        find.descendant(
          of: card,
          matching: find.text('Ben changed where they are paid.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.textContaining('Check with')),
        findsNothing,
      );
    });
  });

  group('a withdrawal in the history', () {
    testWidgets('somebody taken off who joins again is said to', (t) async {
      final wallet = FakeWallet();
      final c = SplitsController(
        wallet: wallet,
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        relay: const UnconfiguredSplitsRelay(),
      );
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(
          name: 'Trip',
          currency: 'USD',
          displayName: 'Ana',
        ))!;
        final ben = otherHost('ben');
        await c.accept(id, [
          entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
        ]);
        wallet.tick();
        final plan = (await c.removalPlan(id, 'ben'))!;
        await c.removePerson(billId: id, id: 'ben', confirmed: plan);
        expect(c.bills.single.bill.participant('ben'), isNull);
        // Removal does not change the bill's key: Ben can still write.
        final benWallet = FakeWallet(id: 'ben', payTo: 'u1ben2');
        for (var i = 0; i < 5; i++) {
          benWallet.tick();
        }
        final later = WalletBillHost(benWallet);
        await c.accept(id, [
          entries.joinBill(host: later, name: 'Ben', payTo: 'u1ben2'),
        ]);
      });
      expect(c.bills.single.bill.participant('ben'), isNotNull);
      await t.pumpWidget(_app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      expect(
        _lines(t),
        anyElement(startsWith('Ben joined again after being taken off')),
      );
    });

    testWidgets('names what it withdrew, and who came off by name', (t) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(
          name: 'Trip',
          currency: 'USD',
          displayName: 'Ana',
        ))!;
        await c.addPerson(billId: id, id: 'ben', name: 'Ben');
        await c.addPerson(billId: id, id: 'cai', name: 'Cai');
        wallet.tick();
        await c.addExpense(
          billId: id,
          paidBy: c.me,
          amountMinorUnits: 3000,
          among: [c.me, 'ben', 'cai'],
          description: 'Taxi',
        );
        final plan = (await c.removalPlan(id, 'ben'))!;
        wallet.tick();
        await c.removePerson(billId: id, id: 'ben', confirmed: plan);
      });
      expect(c.lastError, isNull);
      expect(c.bills.single.bill.participant('ben'), isNull);

      await t.pumpWidget(_app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      final lines = _lines(t);
      final taxi = formatAmount(3000, 'USD');
      // Restated without Ben in the same write: the Taxi he was on reads as
      // withdrawn, the one written in its place does not.
      expect(lines, contains('Ana paid $taxi for Taxi | withdrawn'));
      expect(lines, contains('Ana paid $taxi for Taxi'));
      expect(lines, contains('Ana took Ben off the bill'));
      expect(lines.where((l) => l.contains('withdrew an entry')), isEmpty);
      // Ben's own lines still name him, though he is no longer on the bill.
      expect(lines.where((l) => RegExp(r'\bben\b').hasMatch(l)), isEmpty);
    });

    testWidgets('an address change withdrawn leaves them on the bill', (
      t,
    ) async {
      final wallet = FakeWallet();
      final store = BillStore(InMemoryBillStorage());
      final c = SplitsController(
        wallet: wallet,
        store: store,
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        relay: const UnconfiguredSplitsRelay(),
      );
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(
          name: 'Trip',
          currency: 'USD',
          displayName: 'Ana',
        ))!;
        await c.addPerson(billId: id, id: 'ben', name: 'Ben');
        wallet.tick();
        await c.setAddressFor(billId: id, id: 'ben', address: 'u1benfirst');
        wallet.tick();
        await c.setAddressFor(billId: id, id: 'ben', address: 'u1bensecond');
        final second = (await store.read(id)).lastWhere(
          (e) =>
              e['kind'] == 'joinBill' &&
              (e['participant'] as Map)['payTo'] == 'u1bensecond',
        );
        wallet.tick();
        await c.withdraw(billId: id, entryId: second['id'] as String);
      });
      expect(c.lastError, isNull);
      expect(c.bills.single.bill.participant('ben'), isNotNull);
      await t.pumpWidget(_app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      final lines = _lines(t);
      expect(lines, contains('Ana withdrew a change to where Ben is paid'));
      expect(lines.where((l) => l.contains('off the bill')), isEmpty);
    });

    testWidgets('a correction names the expense it corrected', (t) async {
      final wallet = FakeWallet();
      final c = _controller(wallet);
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(
          name: 'Trip',
          currency: 'USD',
          displayName: 'Ana',
        ))!;
        wallet.tick();
        await c.addExpense(
          billId: id,
          paidBy: c.me,
          amountMinorUnits: 3000,
          among: [c.me],
          description: 'Taxi',
        );
        wallet.tick();
        await c.editExpense(
          billId: id,
          entryId: c.bills.single.expenseEntries.values.single,
          amountMinorUnits: 2500,
        );
      });
      expect(c.lastError, isNull);
      await t.pumpWidget(_app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      expect(
        _lines(t),
        contains(
          'Ana changed the ${formatAmount(3000, 'USD')} expense for Taxi',
        ),
      );
    });

    testWidgets('one naming an entry this device lacks says so plainly', (
      t,
    ) async {
      final c = _controller(FakeWallet());
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(
          name: 'Trip',
          currency: 'USD',
          displayName: 'Ana',
        ))!;
        final cai = otherHost('cai');
        await c.accept(id, [
          entries.joinBill(host: cai, name: 'Cai', payTo: 'u1cai'),
          entries.voidEntry(host: cai, targetId: 'AAAAAAAAAAAAAAAAAAAAAA'),
        ]);
      });
      await t.pumpWidget(_app(c, ActivityScreen(billId: id)));
      await t.pumpAndSettle();
      expect(
        _lines(t).where((l) => l.startsWith('Cai withdrew an entry')),
        isNotEmpty,
      );
    });
  });

  group('leaving while a swap is being forgotten', () {
    for (final leave in [true, false]) {
      testWidgets(
        leave
            ? 'nothing reads the screen once it is gone'
            : 'staying, the list reloads',
        (t) async {
          final storage = _SlowDelete();
          final c = _controller(FakeWallet(), storage);
          late String id;
          await t.runAsync(() async {
            await c.load();
            id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
            await SwapWatchList(storage).add(
              SwapWatch(
                billId: id,
                reference: 'ref-1',
                to: 'ben',
                depositAddress: 't1deposit',
                assetSymbol: 'USDC',
                assetChain: 'base',
              ),
            );
          });
          final nav = GlobalKey<NavigatorState>();
          await t.pumpWidget(
            SplitsScope(
              controller: c,
              child: MaterialApp(navigatorKey: nav, home: const Text('home')),
            ),
          );
          nav.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => ActivityScreen(billId: id)),
          );
          await t.pumpAndSettle();
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await t.pumpAndSettle();
          const forget = Key('splits_inflight_forget_ref-1');
          expect(find.byKey(forget), findsOneWidget);

          final errors = <Object>[];
          await runZonedGuarded(() async {
            storage.hold = true;
            await t.tap(find.byKey(forget));
            await t.pumpAndSettle();
            await t.tap(
              find.byKey(const Key('splits_inflight_forget_confirm_ref-1')),
            );
            await t.pumpAndSettle();
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            if (leave) {
              nav.currentState!.pop();
              await t.pumpAndSettle();
            }
            await t.runAsync(() async {
              storage.hold = false;
              for (final g in storage.waiting) {
                g.complete();
              }
              await Future<void>.delayed(const Duration(milliseconds: 200));
            });
            await t.pumpAndSettle();
          }, (e, s) => errors.add(e));
          expect(errors, isEmpty);
          expect(t.takeException(), isNull);
          expect(await t.runAsync(() => c.swapsInFlight(id)), isEmpty);
          if (!leave) expect(find.byKey(forget), findsNothing);
        },
      );
    }
  });
}
