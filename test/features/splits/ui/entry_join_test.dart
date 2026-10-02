/// The bills list, sharing and joining: what they say, and what one tap does.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/splits_invite_link.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController ctl(
  FakeWallet w, {
  SplitsRelay relay = const UnconfiguredSplitsRelay(),
  int seed = 3,
  SecretStore? secrets,
}) => SplitsController(
  wallet: w,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(
    store: secrets ?? InMemorySecretStore(),
    random: Random(seed),
  ),
  relay: relay,
);

Widget app(SplitsController c, Widget home, {ScanACode? scan}) => SplitsScope(
  controller: c,
  scan: scan,
  child: MaterialApp(key: UniqueKey(), home: home),
);

List<String> texts(WidgetTester t) => [
  for (final w in t.widgetList<Text>(find.byType(Text)))
    w.data ?? w.textSpan?.toPlainText() ?? '',
];

String link(String invite) => protocol.renderInviteLink(
  protocol.parseInvite(invite),
  splitsInviteLinkBase,
);

/// A key store that refuses every bill key while locked, as a keychain does
/// before first unlock.
class LockableSecrets implements SecretStore {
  final _inner = InMemorySecretStore();
  bool locked = false;

  @override
  Future<String?> read(String key) async {
    if (locked && !key.contains('identity')) {
      throw StateError('the keychain is locked');
    }
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (locked && !key.contains('identity')) {
      throw StateError('the keychain is locked');
    }
    return _inner.write(key, value);
  }

  @override
  Future<void> delete(String key) => _inner.delete(key);
}

/// A relay whose fetches wait on [hold], counting them.
class HeldRelay implements SplitsRelay {
  HeldRelay(this.inner);
  final InMemorySplitsRelay inner;
  Completer<void>? hold;
  int fetches = 0;

  @override
  Future<void> push(String channel, List<String> blobs) =>
      inner.push(channel, blobs);

  @override
  Future<List<String>> fetch(String channel) async {
    fetches++;
    await hold?.future;
    return inner.fetch(channel);
  }
}

/// Dinner: Ben paid 20.00 split equally, so this device owes Ben 10.00.
Future<String> dinner(SplitsController c) async {
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benpayable0000000001'),
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
  return id;
}

/// Ana's bill with a placeholder "Ben" she added, and its bill code.
Future<(String, String)> withPlaceholder({required bool benPaid}) async {
  final ana = ctl(FakeWallet(), seed: 1);
  await ana.load();
  final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
  await ana.addPerson(billId: id, id: 'benph', name: 'Ben');
  await ana.addExpense(
    billId: id,
    paidBy: benPaid ? 'benph' : ana.me,
    amountMinorUnits: 2000,
    among: [ana.me, 'benph'],
  );
  expect(ana.lastError, isNull);
  return (id, (await ana.shareableBill(id))!);
}

/// [code], taken by [c] as a scan of it would take it.
Future<void> take(SplitsController c, String code) async {
  final scanned = entries.readScan(code) as entries.ScannedBill;
  await c.acceptKey(scanned.invite!.billId, scanned.invite!.key);
  await c.accept(scanned.invite!.billId, scanned.entries);
  expect(c.lastError, isNull);
}

/// Each run of digits in [t]'s text that starts on one line and ends on
/// another.
List<String> splitFigures(WidgetTester t) {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final p = e.renderObject! as RenderParagraph;
    final text = p.text.toPlainText();
    for (final m in RegExp(r'\d[\d.,]*\d').allMatches(text)) {
      final boxes = p.getBoxesForSelection(
        TextSelection(baseOffset: m.start, extentOffset: m.end),
      );
      if ({for (final b in boxes) b.top.round()}.length > 1) {
        out.add('"${m.group(0)}" in "$text"');
      }
    }
  }
  return out;
}

void main() {
  group('what the bills list says', () {
    testWidgets('a payment this device recorded is said beside the debt', (
      t,
    ) async {
      final c = ctl(FakeWallet());
      await c.load();
      final id = await dinner(c);
      await c.createBill(name: 'Lunch', currency: 'USD');
      await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
      expect(c.lastError, isNull);

      await t.pumpWidget(app(c, const BillsScreen()));
      await t.pumpAndSettle();
      // Still owed until Ben confirms (§10.5), and already on its way.
      expect(find.text('owes 10.00 USD'), findsOneWidget);
      expect(find.text('you owe 10.00 USD'), findsOneWidget);
      expect(
        find.text('10.00 USD sent, not yet confirmed'),
        findsNWidgets(2),
        reason: 'the bill row and the totals row each say it',
      );

      // Ben confirms: nothing is owed and nothing is waiting.
      final view = c.bills.firstWhere((b) => b.id == id);
      final pid = view.bill.payments.single.id;
      await c.accept(id, [
        entries.confirmPayment(
          host: otherHost('ben'),
          paymentId: pid,
          method: 'recipientConfirmed',
          record: view.paymentDigests[pid]!,
        ),
      ]);
      expect(c.lastError, isNull);
      await t.pumpAndSettle();
      expect(find.textContaining('sent, not yet confirmed'), findsNothing);
      expect(find.text('settled'), findsNWidgets(2));
    });

    testWidgets('a debt with nothing sent says nothing about sending', (
      t,
    ) async {
      final c = ctl(FakeWallet());
      await c.load();
      await dinner(c);
      await t.pumpWidget(app(c, const BillsScreen()));
      await t.pumpAndSettle();
      expect(find.text('owes 10.00 USD'), findsOneWidget);
      expect(find.textContaining('sent, not yet confirmed'), findsNothing);
    });

    testWidgets('a bill this device is not on reads "not joined"', (t) async {
      final (_, code) = await withPlaceholder(benPaid: false);
      final ben = ctl(FakeWallet(id: 'ben', payTo: 'u1ben'), seed: 2);
      await ben.load();
      await take(ben, code);
      await t.pumpWidget(app(ben, const BillsScreen()));
      await t.pumpAndSettle();
      expect(find.text('not joined'), findsOneWidget);
      expect(find.text('settled'), findsNothing);
    });

    testWidgets('a joiner whose name a debtor on the bill goes by is shown '
        'that debt', (t) async {
      final (id, code) = await withPlaceholder(benPaid: false);
      final ben = ctl(FakeWallet(id: 'ben', payTo: 'u1ben'), seed: 2);
      await ben.load();
      await take(ben, code);
      await ben.join(id, displayName: 'Ben');
      expect(ben.lastError, isNull);
      await t.pumpWidget(app(ben, const BillsScreen()));
      await t.pumpAndSettle();
      expect(find.text('settled'), findsNothing);
      expect(find.text('Ben (benph) owes 10.00 USD'), findsOneWidget);
    });

    testWidgets('and the same when the one going by their name is owed', (
      t,
    ) async {
      final (id, code) = await withPlaceholder(benPaid: true);
      final ben = ctl(FakeWallet(id: 'ben', payTo: 'u1ben'), seed: 2);
      await ben.load();
      await take(ben, code);
      await ben.join(id, displayName: 'Ben');
      await t.pumpWidget(app(ben, const BillsScreen()));
      await t.pumpAndSettle();
      expect(find.text('Ben (benph) is owed 10.00 USD'), findsOneWidget);
    });

    testWidgets('a joiner by another name, owing nothing, reads "settled"', (
      t,
    ) async {
      final (id, code) = await withPlaceholder(benPaid: false);
      final cara = ctl(FakeWallet(id: 'cara', payTo: 'u1cara'), seed: 4);
      await cara.load();
      await take(cara, code);
      await cara.join(id, displayName: 'Cara');
      await t.pumpWidget(app(cara, const BillsScreen()));
      await t.pumpAndSettle();
      expect(find.text('settled'), findsOneWidget);
    });

    testWidgets('two people called Ben on two bills are told apart', (t) async {
      final c = ctl(FakeWallet());
      await c.load();
      final a = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      await c.addPerson(billId: a, id: 'benA', name: 'Ben');
      await c.addExpense(
        billId: a,
        paidBy: 'benA',
        amountMinorUnits: 2000,
        among: [c.me, 'benA'],
      );
      final b = (await c.createBill(name: 'Taxi', currency: 'USD'))!;
      await c.addPerson(billId: b, id: 'benB', name: 'Ben');
      await c.addExpense(
        billId: b,
        paidBy: c.me,
        amountMinorUnits: 2000,
        among: [c.me, 'benB'],
      );
      expect(c.lastError, isNull);
      await t.pumpWidget(app(c, const BillsScreen()));
      await t.pumpAndSettle();
      expect(find.text('Ben'), findsNothing);
      expect(find.text('Ben · Dinner'), findsOneWidget);
      expect(find.text('Ben · Taxi'), findsOneWidget);
    });

    testWidgets('two bills of one name are told apart by id', (t) async {
      final c = ctl(FakeWallet());
      await c.load();
      for (final ben in ['benA', 'benB']) {
        final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
        await c.addPerson(billId: id, id: ben, name: 'Ben');
        await c.addExpense(
          billId: id,
          paidBy: ben,
          amountMinorUnits: 2000,
          among: [c.me, ben],
        );
      }
      await t.pumpWidget(app(c, const BillsScreen()));
      await t.pumpAndSettle();
      expect(find.text('Ben · Dinner (benA)'), findsOneWidget);
      expect(find.text('Ben · Dinner (benB)'), findsOneWidget);
    });

    testWidgets('one person on two bills is one plain row', (t) async {
      final c = ctl(FakeWallet());
      await c.load();
      final ben = await SignedPeer.named('ben');
      for (final name in ['Dinner', 'Taxi']) {
        final id = (await c.createBill(name: name, currency: 'USD'))!;
        await c.accept(id, [
          await ben.join(id, name: 'Ben', payTo: 'u1benpayable0000000001'),
          await ben.sign(
            entries.addExpense(
              host: ben.host,
              expenseId: 'x$name',
              paidBy: ben.id,
              amount: 2000,
              split: <String, dynamic>{
                'type': 'equal',
                'among': [ben.id, c.me]..sort(),
              },
            ),
            id,
          ),
        ]);
        expect(c.lastError, isNull);
      }
      await t.pumpWidget(app(c, const BillsScreen()));
      await t.pumpAndSettle();
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('you owe 20.00 USD'), findsOneWidget);
    });
  });

  group('a figure never breaks inside its digits', () {
    for (final (minor, label) in [
      (123456, '1234.56'),
      (12345678, '123456.78'),
      (92233720368, '922337203.68'),
    ]) {
      for (final width in [320.0, 375.0]) {
        for (final scale in [1.0, 1.3, 2.0]) {
          testWidgets('$label at $width, text x$scale', (t) async {
            t.view.physicalSize = Size(width * 3, 812 * 3);
            t.view.devicePixelRatio = 3;
            addTearDown(t.view.reset);
            final c = ctl(FakeWallet());
            await c.load();
            for (var i = 0; i < 2; i++) {
              final id = (await c.createBill(
                name: 'Dinner in Lisbon $i',
                currency: 'EUR',
              ))!;
              final b = await SignedPeer.named(i == 0 ? 'priyanka' : 'bart');
              await c.accept(id, [
                await b.join(
                  id,
                  name: i == 0 ? 'Priyanka Raghunathan' : 'Bartholomew',
                  payTo: 'u1x$i',
                ),
                await b.sign(
                  entries.addExpense(
                    host: b.host,
                    expenseId: 'x$i',
                    paidBy: b.id,
                    amount: minor,
                    split: <String, dynamic>{
                      'type': 'equal',
                      'among': [c.me],
                    },
                  ),
                  id,
                ),
              ]);
              expect(c.lastError, isNull);
            }
            await t.pumpWidget(
              SplitsScope(
                controller: c,
                child: MaterialApp(
                  builder: (ctx, child) => MediaQuery(
                    data: MediaQuery.of(
                      ctx,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: const BillsScreen(),
                ),
              ),
            );
            await t.pumpAndSettle();
            expect(find.textContaining(label), findsWidgets);
            expect(splitFigures(t), isEmpty);
            expect(t.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('control: the probe sees a figure forced to break', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(width: 40, child: Text('owes 12345678.90 EUR')),
          ),
        ),
      );
      expect(splitFigures(t), isNotEmpty);
    });
  });

  group('sharing', () {
    Future<(SplitsController, String)> tooBig(SplitsRelay relay) async {
      final ana = ctl(FakeWallet(), seed: 1, relay: relay);
      await ana.load();
      final id = (await ana.createBill(name: 'Trip', currency: 'USD'))!;
      var n = 0;
      while (await ana.shareableBill(id) != null) {
        await ana.addExpense(
          billId: id,
          paidBy: ana.me,
          amountMinorUnits: 1000 + n,
          among: [ana.me],
          description: 'Expense number $n with a description',
        );
        expect(ana.lastError, isNull);
        n++;
      }
      return (ana, id);
    }

    testWidgets('past the cap with no relay, no invite is offered and the '
        'reason is said', (t) async {
      final (ana, id) = await tooBig(const UnconfiguredSplitsRelay());
      await t.pumpWidget(app(ana, ShareBillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_share_too_big')), findsOneWidget);
      expect(find.textContaining('no bill relay'), findsOneWidget);
      expect(find.byType(CodeImage), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('past the cap with a relay, the invite is offered and said '
        'to bring the bill', (t) async {
      final (ana, id) = await tooBig(InMemorySplitsRelay());
      await t.pumpWidget(app(ana, ShareBillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('splits_share_too_big')), findsOneWidget);
      expect(find.textContaining('Share the invite'), findsOneWidget);
      expect(find.text('Invite'), findsOneWidget);
      expect(find.text('Bill code'), findsNothing);
    });

    testWidgets('a bill that fits shows both codes and no notice', (t) async {
      final ana = ctl(FakeWallet(), seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Small', currency: 'USD'))!;
      await t.pumpWidget(app(ana, ShareBillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.text('Bill code'), findsOneWidget);
      expect(find.text('Invite'), findsOneWidget);
      expect(find.byKey(const Key('splits_share_too_big')), findsNothing);
    });

    testWidgets('a key that cannot be read is said, not left loading', (
      t,
    ) async {
      final secrets = LockableSecrets();
      final ana = ctl(FakeWallet(), seed: 1, secrets: secrets);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      secrets.locked = true;
      await t.pumpWidget(app(ana, ShareBillScreen(billId: id)));
      await t.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byKey(const Key('splits_share_failed')), findsOneWidget);
      expect(find.textContaining('Unlock the wallet'), findsOneWidget);
    });
  });

  group('joining', () {
    testWidgets('an invite whose key opens nothing on the relay says so', (
      t,
    ) async {
      final relay = InMemorySplitsRelay();
      final ana = ctl(FakeWallet(), relay: relay, seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      await ana.syncBill(id);

      final other = ctl(FakeWallet(id: 'cara'), seed: 99);
      await other.load();
      final decoy = (await other.createBill(name: 'X', currency: 'USD'))!;
      final forged = protocol.renderInviteLink(
        protocol.Invite(
          billId: id,
          key: await other.billKey(decoy),
          name: 'Dinner',
        ),
        splitsInviteLinkBase,
      );

      final ben = ctl(
        FakeWallet(id: 'ben', payTo: 'u1ben'),
        relay: relay,
        seed: 2,
      );
      await ben.load();
      await t.pumpWidget(app(ben, ScanBillScreen(initialCode: forged)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();
      expect(ben.syncStateOf(id).unopenable, greaterThan(0));
      expect(find.textContaining('key doesn’t open'), findsOneWidget);
      expect(find.textContaining('Joined'), findsNothing);

      // The genuine invite opens the bill.
      final ben2 = ctl(
        FakeWallet(id: 'ben', payTo: 'u1ben'),
        relay: relay,
        seed: 5,
      );
      await ben2.load();
      await t.pumpWidget(
        app(ben2, ScanBillScreen(initialCode: link(await ana.inviteFor(id)))),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();
      expect(find.byType(BillScreen), findsOneWidget);
    });

    testWidgets('a bill not on the relay yet is named as such, looked for '
        'while the screen is open, and opened when it arrives', (t) async {
      final relay = InMemorySplitsRelay();
      final ana = ctl(FakeWallet(), relay: relay, seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      final invite = link(await ana.inviteFor(id));
      final ben = ctl(
        FakeWallet(id: 'ben', payTo: 'u1ben'),
        relay: relay,
        seed: 2,
      );
      await ben.load();
      await t.pumpWidget(app(ben, ScanBillScreen(initialCode: invite)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();
      expect(find.textContaining('hasn’t reached the relay yet'), findsOne);
      expect(find.textContaining('open the invite again'), findsOneWidget);
      expect(find.byType(BillScreen), findsNothing);

      await ana.syncBill(id);
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      expect(find.byType(BillScreen), findsOneWidget);
      expect(ben.bills.single.id, id);
    });

    testWidgets('leaving before the bill arrives stops looking for it', (
      t,
    ) async {
      final relay = InMemorySplitsRelay();
      final ana = ctl(FakeWallet(), relay: relay, seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      final invite = link(await ana.inviteFor(id));
      final ben = ctl(
        FakeWallet(id: 'ben', payTo: 'u1ben'),
        relay: relay,
        seed: 2,
      );
      await ben.load();
      await t.pumpWidget(app(ben, ScanBillScreen(initialCode: invite)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      await ana.syncBill(id);
      await t.pump(const Duration(minutes: 1));
      expect(ben.bills, isEmpty);
    });

    testWidgets('with no relay, a joiner is asked for the sender’s code, not '
        'told to scan one', (t) async {
      final ana = ctl(FakeWallet(), seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      final ben = ctl(FakeWallet(id: 'ben', payTo: 'u1ben'), seed: 2);
      await ben.load();
      await t.pumpWidget(
        app(ben, ScanBillScreen(initialCode: link(await ana.inviteFor(id)))),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();
      expect(find.textContaining('Now scan the bill’s code'), findsNothing);
      expect(find.textContaining('ask whoever sent the invite'), findsOne);
    });

    testWidgets('a key store that fails on Join is said', (t) async {
      final ana = ctl(FakeWallet(), seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      final code = (await ana.shareableBill(id))!;
      final secrets = LockableSecrets();
      final ben = ctl(
        FakeWallet(id: 'ben', payTo: 'u1ben'),
        seed: 2,
        secrets: secrets,
      );
      await ben.load();
      secrets.locked = true;
      await t.pumpWidget(app(ben, ScanBillScreen(initialCode: code)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.textContaining('keys couldn’t be read'), findsOneWidget);
      expect(find.byType(BillScreen), findsNothing);

      // Unlocked, the same tap takes the bill.
      secrets.locked = false;
      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();
      expect(find.byType(BillScreen), findsOneWidget);
    });

    testWidgets('a bill code is previewed by the bill’s name, an unnamed '
        'invite as unnamed', (t) async {
      final ana = ctl(FakeWallet(), seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      final ben = ctl(FakeWallet(id: 'ben', payTo: 'u1ben'), seed: 2);
      await ben.load();
      await t.pumpWidget(
        app(ben, ScanBillScreen(initialCode: (await ana.shareableBill(id))!)),
      );
      await t.pumpAndSettle();
      expect(
        find.textContaining('A bill code for “Dinner”, as its sender named it'),
        findsOneWidget,
      );
      expect(find.textContaining('“”'), findsNothing);

      await t.pumpWidget(
        app(
          ben,
          ScanBillScreen(initialCode: link(await ana.inviteFor(id, name: ''))),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.textContaining('An invite to a bill with no name'),
        findsOneWidget,
      );
      expect(find.textContaining('“”'), findsNothing);
    });

    testWidgets('a camera scan is previewed, and joined only when asked', (
      t,
    ) async {
      final relay = InMemorySplitsRelay();
      final ana = ctl(FakeWallet(), relay: relay, seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Rent split', currency: 'USD'))!;
      await ana.syncBill(id);
      final invite = link(await ana.inviteFor(id, name: 'Coffee'));
      final secrets = InMemorySecretStore();
      final ben = ctl(
        FakeWallet(id: 'ben', payTo: 'u1ben'),
        relay: relay,
        seed: 2,
        secrets: secrets,
      );
      await ben.load();
      await t.pumpWidget(
        app(ben, const ScanBillScreen(), scan: (_) async => invite),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_scan_camera')));
      await t.pumpAndSettle();
      expect(find.byType(BillScreen), findsNothing);
      expect(await SplitsKeys(store: secrets).readBillKey(id), isNull);
      expect(
        find.textContaining('An invite to “Coffee”, as its sender named it'),
        findsOneWidget,
      );
      expect(find.text('Join'), findsOneWidget);

      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();
      expect(find.byType(BillScreen), findsOneWidget);
    });

    testWidgets('a pasted code is previewed, and a changed one previewed '
        'again', (t) async {
      final ana = ctl(FakeWallet(), seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      final other = (await ana.createBill(name: 'Taxi', currency: 'USD'))!;
      final ben = ctl(FakeWallet(id: 'ben', payTo: 'u1ben'), seed: 2);
      await ben.load();
      await t.pumpWidget(app(ben, const ScanBillScreen()));
      await t.enterText(find.byType(TextField), (await ana.shareableBill(id))!);
      await t.tap(find.text('Read it'));
      await t.pumpAndSettle();
      expect(find.textContaining('“Dinner”'), findsOneWidget);
      expect(ben.bills, isEmpty);

      await t.enterText(
        find.byType(TextField),
        (await ana.shareableBill(other))!,
      );
      await t.pump();
      expect(find.text('Read it'), findsOneWidget);
      await t.tap(find.text('Read it'));
      await t.pumpAndSettle();
      expect(find.textContaining('“Taxi”'), findsOneWidget);
      expect(ben.bills, isEmpty);
      await t.tap(find.text('Join'));
      await t.pumpAndSettle();
      expect(ben.bills.single.bill.name, 'Taxi');
    });

    testWidgets('a code that is not one is refused on the first tap', (
      t,
    ) async {
      final c = ctl(FakeWallet());
      await c.load();
      await t.pumpWidget(app(c, const ScanBillScreen()));
      await t.enterText(find.byType(TextField), 'splitz1:notacode');
      await t.tap(find.text('Read it'));
      await t.pumpAndSettle();
      expect(find.textContaining('('), findsOneWidget);
    });

    testWidgets('Join while the relay is slow shows it, and a second tap '
        'starts nothing', (t) async {
      final inner = InMemorySplitsRelay();
      final ana = ctl(FakeWallet(), relay: inner, seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      await ana.syncBill(id);
      final invite = link(await ana.inviteFor(id));

      final relay = HeldRelay(inner)..hold = Completer<void>();
      final vic = ctl(
        FakeWallet(id: 'vic', payTo: 'u1vic'),
        relay: relay,
      );
      await vic.load();
      await t.pumpWidget(app(vic, ScanBillScreen(initialCode: invite)));
      await t.pumpAndSettle();
      final join = find.byKey(const Key('splits_scan_read'));
      expect(t.widget<FilledButton>(join).onPressed, isNotNull);

      await t.tap(join);
      await t.pump(const Duration(milliseconds: 100));
      expect(t.widget<FilledButton>(join).onPressed, isNull);
      expect(find.byKey(const Key('splits_scan_joining')), findsOneWidget);
      await t.tap(join, warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 100));
      expect(relay.fetches, 1);

      relay.hold!.complete();
      await t.pumpAndSettle();
      expect(find.byType(BillScreen), findsOneWidget);
    });

    testWidgets('two taps on Join in one frame join once', (t) async {
      final inner = InMemorySplitsRelay();
      final ana = ctl(FakeWallet(), relay: inner, seed: 1);
      await ana.load();
      final id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      await ana.syncBill(id);
      final relay = HeldRelay(inner)..hold = Completer<void>();
      final vic = ctl(
        FakeWallet(id: 'vic', payTo: 'u1vic'),
        relay: relay,
      );
      await vic.load();
      await t.pumpWidget(
        app(vic, ScanBillScreen(initialCode: link(await ana.inviteFor(id)))),
      );
      await t.pumpAndSettle();
      final join = find.byKey(const Key('splits_scan_read'));
      await t.tap(join);
      await t.tap(join);
      await t.pump(const Duration(milliseconds: 100));
      // Counted while held: the bill screen polls once it opens.
      expect(relay.fetches, 1);
      relay.hold!.complete();
      await t.pumpAndSettle();
      expect(find.byType(BillScreen), findsOneWidget);
    });
  });

  group('opening a bill', () {
    testWidgets('two taps in one frame open one bill', (t) async {
      final c = ctl(FakeWallet());
      await c.load();
      await t.pumpWidget(app(c, const NewBillScreen()));
      await t.enterText(find.byType(TextFormField).first, 'Dinner');
      await t.pump();
      final open = find.byKey(const Key('splits_new_bill_open'));
      await t.tap(open);
      await t.tap(open);
      await t.pumpAndSettle();
      expect(c.bills, hasLength(1));
      expect(find.byType(BillScreen), findsOneWidget);
    });

    testWidgets('a refused bill can be opened again after fixing it', (
      t,
    ) async {
      final c = ctl(FakeWallet());
      await c.load();
      await t.pumpWidget(app(c, const NewBillScreen()));
      final open = find.byKey(const Key('splits_new_bill_open'));
      await t.tap(open);
      await t.pumpAndSettle();
      expect(find.text('Give the bill a name'), findsOneWidget);
      await t.enterText(find.byType(TextFormField).first, 'Dinner');
      await t.tap(open);
      await t.pumpAndSettle();
      expect(c.bills, hasLength(1));
    });
  });

  group('links into an open feature', () {
    Future<GlobalKey<SplitsNavigatorState>> mount(
      WidgetTester t,
      SplitsController c,
    ) async {
      final nav = GlobalKey<SplitsNavigatorState>();
      await t.pumpWidget(
        MaterialApp(
          home: SplitsNavigator(key: nav, controller: c),
        ),
      );
      await t.pumpAndSettle();
      return nav;
    }

    int joinScreens() =>
        find.byType(ScanBillScreen, skipOffstage: false).evaluate().length;

    testWidgets('a second link replaces the Join screen the first opened', (
      t,
    ) async {
      final ana = ctl(FakeWallet(), seed: 1);
      await ana.load();
      final x = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
      final y = (await ana.createBill(name: 'Taxi', currency: 'USD'))!;
      final c = ctl(FakeWallet(id: 'ben', payTo: 'u1ben'), seed: 2);
      await c.load();
      final nav = await mount(t, c);
      nav.currentState!.openCode(link(await ana.inviteFor(x)));
      await t.pumpAndSettle();
      nav.currentState!.openCode(link(await ana.inviteFor(y)));
      await t.pumpAndSettle();
      expect(joinScreens(), 1);
      expect(find.textContaining('“Taxi”'), findsOneWidget);
      // Back from it lands on the list, not on the first link.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(joinScreens(), 0);
      expect(find.byType(BillsScreen), findsOneWidget);
    });

    testWidgets('a link replaces a Join screen opened by hand', (t) async {
      final c = ctl(FakeWallet());
      await c.load();
      final nav = await mount(t, c);
      await t.tap(find.byKey(const Key('splits_join_bill')));
      await t.pumpAndSettle();
      nav.currentState!.openCode('splitz1:x');
      await t.pumpAndSettle();
      expect(joinScreens(), 1);
    });

    testWidgets('a link over another screen is pushed over it', (t) async {
      final c = ctl(FakeWallet());
      await c.load();
      final nav = await mount(t, c);
      await t.tap(find.byKey(const Key('splits_start_bill')));
      await t.pumpAndSettle();
      nav.currentState!.openCode('splitz1:x');
      await t.pumpAndSettle();
      expect(joinScreens(), 1);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byType(NewBillScreen), findsOneWidget);
    });
  });
}
