// What the settle flow's screens draw and say, on the phone sizes and text
// sizes a payer uses: the send review, the removal dialog, the bills list,
// the swap screen and the settle screen's rows.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_address_verify_sheet.dart';
import 'package:zcash_wallet/src/core/widgets/review_list_row.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';
import 'support/closing.dart';

import 'support/screen_harness.dart';
import 'swap_screens_test.dart' show FakeSwaps;

const _unexplained = 'No debt the bill records for you explains';

const _widths = [320.0, 360.0, 375.0, 393.0, 412.0];
const _scales = [1.0, 1.15, 1.3, 2.0];

/// The words of [p] drawn across two lines: the line holding a word's first
/// character is not the one holding its last.
List<String> brokenWords(RenderParagraph p) {
  final painter = TextPainter(
    text: p.text,
    textDirection: p.textDirection,
    textAlign: p.textAlign,
    textScaler: p.textScaler,
    maxLines: p.maxLines,
  )..layout(maxWidth: p.constraints.maxWidth);
  final broken = [
    for (final m in RegExp(r'\S+').allMatches(p.text.toPlainText()))
      if (painter.getLineBoundary(TextPosition(offset: m.start)) !=
          painter.getLineBoundary(TextPosition(offset: m.end - 1)))
        m.group(0)!,
  ];
  painter.dispose();
  return broken;
}

/// The one paragraph under [of] that draws exactly [text].
RenderParagraph paragraph(WidgetTester t, Finder of, String text) {
  final found = [
    for (final p
        in find
            .descendant(of: of, matching: find.byType(RichText))
            .evaluate()
            .map((e) => e.renderObject)
            .whereType<RenderParagraph>())
      // A word joiner draws nothing.
      if (p.text.toPlainText().replaceAll('\u2060', '') == text) p,
  ];
  expect(found, hasLength(1), reason: 'one paragraph draws "$text"');
  return found.single;
}

/// [p]'s box on screen.
Rect rectOf(RenderParagraph p) =>
    MatrixUtils.transformRect(p.getTransformTo(null), Offset.zero & p.size);

/// Everything drawn as text under [of], in order: what a person can read.
List<String> shownText(WidgetTester t, Finder of) => [
  for (final w in t.widgetList<Text>(
    find.descendant(of: of, matching: find.byType(Text)),
  ))
    w.data ?? w.textSpan?.toPlainText() ?? '',
];

/// Two payees both called Priyanka, at unified-address length, owed amounts
/// whose ZEC runs to every digit at 31.97 USD a ZEC.
const List<Payee> _twins = [
  (id: 'pr1aaaaaaaa1', name: 'Priyanka', address: '', owe: 25000000),
  (id: 'pr2bbbbbbbb2', name: 'Priyanka', address: '', owe: 39470),
];

List<Payee> get twins => [
  for (final p in _twins)
    (id: p.id, name: p.name, address: ua(p.id), owe: p.owe),
];

Future<(SplitsController, String)> openTwinsReview(
  WidgetTester t, {
  required double width,
  required double scale,
  bool dark = false,
  List<String>? overflowed,
}) async {
  await fonts();
  await setSize(t, width, 3.0, scale: scale);
  final c = controllerWith();
  late String id;
  await t.runAsync(() async => id = await owing(c, twins, rate: 3197));
  final seen = await overflows(() async {
    await t.pumpWidget(host(c, SettleScreen(billId: id), dark: dark));
    await t.pumpAndSettle();
    await openReview(t);
  });
  overflowed?.addAll(seen);
  return (c, id);
}

void main() {
  group('the send review', () {
    for (final width in _widths) {
      for (final scale in _scales) {
        for (final dark in [false, true]) {
          testWidgets('every amount, payee and address whole at '
              '$width@$scale ${dark ? 'dark' : 'light'}', (t) async {
            final overflowed = <String>[];
            final (c, id) = await openTwinsReview(
              t,
              width: width,
              scale: scale,
              dark: dark,
              overflowed: overflowed,
            );
            expect(overflowed, isEmpty);
            final review = find.byKey(const Key('splits_review'));
            expect(cutText(t, within: review), isEmpty);
            final owed = (await t.runAsync(() => c.obligation(id)))!;
            final view = c.bills.single;
            final payments = owed.request.payments;
            expect(payments, hasLength(2));
            for (final (i, p) in payments.indexed) {
              final row = find.byKey(Key('splits_review_payment_$i'));
              await t.ensureVisible(row);
              await t.pumpAndSettle();
              final amount = paragraph(t, row, formatZec(p.zatoshi));
              final name = paragraph(
                t,
                row,
                view.bill.displayNameOf(
                  owed.request.recipients[i],
                  creatorId: view.creatorId,
                ),
              );
              expect(name.text.toPlainText(), contains('('));
              final address = paragraph(t, row, reviewAddress(p.address));
              for (final drawn in [amount, name, address]) {
                final box = rectOf(drawn);
                expect(box.left, greaterThanOrEqualTo(0));
                expect(box.right, lessThanOrEqualTo(width + 0.5));
                expect(drawn.didExceedMaxLines, isFalse);
              }
              expect(brokenWords(name), isEmpty);
              // Drawn at a size a person reads, not shrunk to a sliver.
              expect(rectOf(amount).height, greaterThanOrEqualTo(16));
              expect(rectOf(name).height, greaterThanOrEqualTo(16));
              // §14.2: the first ten characters, then a break.
              expect(
                address.text.toPlainText().substring(0, 10),
                p.address.substring(0, 10),
              );
            }
          });
        }
      }
    }

    for (final width in [320.0, 393.0]) {
      testWidgets('Show full address opens the sheet at $width@2.0', (t) async {
        await openTwinsReview(t, width: width, scale: 2.0);
        final button = find.byKey(const Key('splits_review_full_address_0'));
        await t.ensureVisible(button);
        await t.pumpAndSettle();
        await t.tap(button);
        await t.pumpAndSettle();
        expect(find.byType(MobileAddressVerifySheet), findsOneWidget);
      });
    }

    testWidgets('a total either carries the fee or says it does not', (
      t,
    ) async {
      final (c, id) = await openTwinsReview(t, width: 393, scale: 1.0);
      final owed = (await t.runAsync(() => c.obligation(id)))!;
      final total = t.widget<ReviewListRow>(
        find.descendant(
          of: find.byKey(const Key('splits_review')),
          matching: find.byWidgetPredicate(
            (w) => w is ReviewListRow && w.label.startsWith('Total'),
          ),
        ),
      );
      // Both outputs and the harness wallet's 10,000-zatoshi fee.
      final withFee =
          owed.request.payments.fold(0, (a, p) => a + p.zatoshi) + 10000;
      expect(total.label, 'Total');
      expect(total.value, formatZec(withFee));
    });

    testWidgets('a fee not yet worked out is said, not left grey', (t) async {
      await fonts();
      await setSize(t, 393, 3.0);
      final pending = Completer<SendPreview>();
      final c = controllerWith(preview: (_) => pending.future);
      late String id;
      await t.runAsync(() async => id = await owing(c, twins, rate: 3197));
      await t.pumpWidget(host(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      await openReview(t);
      final shown = shownText(t, find.byKey(const Key('splits_review')));
      expect(shown.where((s) => s.contains('Working out the fee')), isNotEmpty);
      final total = shown.indexWhere((s) => s.startsWith('Total'));
      expect(shown[total], 'Total before fee');
      pending.complete(const SendPreview(feeZatoshi: 10000));
      await t.pumpAndSettle();
      expect(
        shownText(
          t,
          find.byKey(const Key('splits_review')),
        ).where((s) => s.contains('Working out the fee')),
        isEmpty,
      );
    });

    /// A bill where this device owes Ben 10.00 plus a 5.00 refund Cara
    /// entered against it, Dan 10.00, and Cai 15.00 at no address; [then]
    /// runs before it is priced.
    Future<(SplitsController, FakeWallet, BillStorage, String)> trip(
      WidgetTester t, {
      Future<void> Function(SplitsController c, String id)? then,
    }) async {
      final wallet = FakeWallet();
      final storage = InMemoryBillStorage();
      final c = SplitsController(
        wallet: wallet,
        store: BillStore(storage),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        relay: const UnconfiguredSplitsRelay(),
        previewSend: (_) async => const SendPreview(feeZatoshi: 10000),
      );
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
        final ben = otherHost('ben');
        final cara = otherHost('cara');
        final dan = otherHost('dan');
        await c.accept(id, [
          entries.joinBill(
            host: ben,
            name: 'Ben',
            payTo: 'u1benpayable0000000001',
          ),
          entries.joinBill(
            host: cara,
            name: 'Cara',
            payTo: 'u1carapayable000000001',
          ),
          entries.joinBill(
            host: dan,
            name: 'Dan',
            payTo: 'u1danpayable0000000001',
          ),
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
          // Cara says the payer took a 5.00 refund that was Ben's.
          entries.addExpense(
            host: cara,
            expenseId: 'x2',
            paidBy: c.me,
            amount: -500,
            split: const <String, dynamic>{
              'type': 'equal',
              'among': ['ben'],
            },
          ),
          entries.addExpense(
            host: dan,
            expenseId: 'x3',
            paidBy: 'dan',
            amount: 2000,
            split: <String, dynamic>{
              'type': 'equal',
              'among': ['dan', c.me]..sort(),
            },
          ),
        ]);
        wallet.tick();
        await c.addPerson(billId: id, id: 'cai', name: 'Cai');
        wallet.tick();
        await c.addExpense(
          billId: id,
          paidBy: 'cai',
          amountMinorUnits: 3000,
          among: [c.me, 'cai'],
          description: 'Taxi',
        );
        wallet.tick();
        await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
        await closeForSettling(c, id);
        await then?.call(c, id);
      });
      expect(c.lastError, isNull);
      return (c, wallet, storage, id);
    }

    /// What the §14.2 kit finds missing from the review of [id].
    Future<(List<String>, List<String>)> kit(
      WidgetTester t,
      SplitsController c,
      FakeWallet wallet,
      BillStorage storage,
      String id,
    ) async {
      final owed = (await t.runAsync(() => c.obligation(id)))!;
      await t.pumpWidget(host(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      await openReview(t);
      final shown = shownText(t, find.byKey(const Key('splits_review')));
      late List<ReviewFinding> findings;
      await t.runAsync(() async {
        findings = checkPayerReview(
          obligation: owed,
          folded: await foldVerified(
            wallet,
            await BillStore(storage).read(id),
            billId: id,
          ),
          visibleText: shown,
          // The settle screen's words for each reason, and for a part of a
          // payment no debt explains.
          reasonWords: const {'no_address': 'No Zcash address yet'},
          unexplainedWords: _unexplained,
        );
      });
      return ([for (final f in findings) '$f'], shown);
    }

    testWidgets('the page the payer confirms on says who it cannot pay and '
        'what no debt explains (§14.2 kit)', (t) async {
      final (c, wallet, storage, id) = await trip(t);
      final owed = (await t.runAsync(() => c.obligation(id)))!;
      expect(owed.unpayable.map((u) => '${u.id}:${u.reason}'), [
        'cai:no_address',
      ]);
      expect(owed.settlements.any((s) => s.unexplained > 0), isTrue);
      final (findings, shown) = await kit(t, c, wallet, storage, id);
      expect(findings, isEmpty);
      // The same words the settle screen shows for the same debts.
      expect(shown.join('\n'), contains('No Zcash address yet'));
      expect(shown.join('\n'), contains('A refund entered by Cara'));
    });

    testWidgets('the page the payer confirms on says what is still awaiting '
        'confirmation (§14.2 kit)', (t) async {
      final (c, wallet, storage, id) = await trip(
        t,
        // Paid Dan in cash; he has not confirmed it.
        then: (c, id) =>
            c.recordCash(billId: id, to: 'dan', amountMinorUnits: 1000),
      );
      final owed = (await t.runAsync(() => c.obligation(id)))!;
      expect(owed.awaiting.map((a) => a.to), contains('dan'));
      final (findings, shown) = await kit(t, c, wallet, storage, id);
      expect(findings, isEmpty);
      expect(shown.join('\n'), contains('sent, not yet confirmed'));
    });
  });

  group('taking somebody off a bill', () {
    Future<(SplitsController, String)> bill(
      WidgetTester t, {
      String? n1 = 'Priyanka',
      String? n2 = 'Priyanka',
      String? me,
      int amount = 123456,
    }) async {
      final c = controllerWith();
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(
          name: 'Dinner',
          currency: 'USD',
          displayName: me,
        ))!;
        await c.accept(id, [
          entries.joinBill(
            host: otherHost('p1aaaaaaaa01'),
            name: n1,
            payTo: ua('p1'),
          ),
          entries.joinBill(
            host: otherHost('p2bbbbbbbb02'),
            name: n2,
            payTo: ua('p2'),
          ),
        ]);
        await c.addExpense(
          billId: id,
          paidBy: c.me,
          amountMinorUnits: amount,
          among: [c.me, 'p1aaaaaaaa01', 'p2bbbbbbbb02'],
          description: 'Beach house',
        );
      });
      expect(c.lastError, isNull);
      await t.pumpWidget(host(c, PeopleScreen(billId: id)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_person_remove_p1aaaaaaaa01')));
      await t.pumpAndSettle();
      return (c, id);
    }

    String title(WidgetTester t) =>
        (t.widget<AlertDialog>(find.byType(AlertDialog)).title! as Text).data!;

    testWidgets('the title names them as the people list does', (t) async {
      final (c, _) = await bill(t);
      final view = c.bills.single;
      final listed = view.bill.displayNameOf(
        'p1aaaaaaaa01',
        creatorId: view.creatorId,
      );
      expect(listed, isNot('Priyanka'));
      expect(title(t), 'Take $listed off the bill?');
    });

    testWidgets('an unnamed joiner is still named', (t) async {
      await bill(t, n1: null, n2: 'Ben');
      expect(title(t), isNot(contains('Take  off')));
      expect(title(t), matches(RegExp(r'^Take \S.* off the bill\?$')));
    });

    for (final me in [null, 'Kamal']) {
      testWidgets('this device is marked as you (name: $me)', (t) async {
        final (c, _) = await bill(t, me: me);
        final line = t
            .widget<Text>(find.byKey(Key('splits_people_remove_moves_${c.me}')))
            .data!;
        expect(line, contains('(you)'));
        if (me != null) expect(line, contains(me));
      });
    }

    testWidgets('a refund moves by its size, said the right way round', (
      t,
    ) async {
      final c = controllerWith();
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
        final ben = otherHost('ben');
        await c.accept(id, [
          entries.joinBill(host: ben, name: 'Ben', payTo: 'u1ben'),
        ]);
        await c.addPerson(billId: id, id: 'cai', name: 'Cai');
        await c.accept(id, [
          entries.addExpense(
            host: ben,
            expenseId: 'xr',
            paidBy: 'ben',
            amount: -3000,
            description: 'Refund',
            split: <String, dynamic>{
              'type': 'equal',
              'among': ['ben', 'cai', c.me]..sort(),
            },
          ),
        ]);
      });
      expect(c.lastError, isNull);
      final cai = c.bills.single.bill.participant('cai')!;
      await t.pumpWidget(
        host(
          c,
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  confirmAndRemovePerson(context, billId: id, participant: cai),
              child: const Text('remove'),
            ),
          ),
        ),
      );
      await t.tap(find.text('remove'));
      await t.pumpAndSettle();
      final said = shownText(t, find.byType(AlertDialog));
      // Cai's 10.00 back moves to Ben and this device, 5.00 each: each now
      // pays 5.00 less.
      expect(said.where((s) => s.contains(RegExp(r'-\d'))), isEmpty);
      expect(said, contains('• Ben pays 5.00 USD less'));
      expect(
        said,
        contains(
          'The 10.00 USD they were to get back from 1 expense moves to the '
          'others:',
        ),
      );
    });
  });

  group('the bills list', () {
    Future<String> owesBen(SplitsController c) async {
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
      final ben = otherHost('ben');
      await c.accept(id, [
        entries.joinBill(
          host: ben,
          name: 'Ben',
          payTo: 'u1benpayable0000000001',
        ),
        entries.addExpense(
          host: ben,
          expenseId: 'x1',
          paidBy: 'ben',
          amount: 2000,
          split: <String, dynamic>{
            'type': 'equal',
            'among': [c.me, 'ben']..sort(),
          },
        ),
      ]);
      return id;
    }

    testWidgets('one bill: a payment not yet confirmed is still said', (
      t,
    ) async {
      final c = controllerWith();
      await t.runAsync(() async {
        final id = await owesBen(c);
        await closeForSettling(c, id);
        await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
      });
      expect(c.lastError, isNull);
      expect(c.bills, hasLength(1));
      await t.pumpWidget(host(c, const BillsScreen()));
      await t.pumpAndSettle();
      expect(find.text('10.00 USD sent, not yet confirmed'), findsOneWidget);
    });

    testWidgets('a debt says which way it runs in words', (t) async {
      final c = controllerWith();
      late String owe, owed;
      await t.runAsync(() async {
        owe = await owesBen(c);
        owed = (await c.createBill(name: 'Lunch', currency: 'USD'))!;
        await c.addPerson(billId: owed, id: 'cai', name: 'Cai');
        await c.addExpense(
          billId: owed,
          paidBy: c.me,
          amountMinorUnits: 2000,
          among: [c.me, 'cai'],
          description: 'x',
        );
      });
      await t.pumpWidget(host(c, const BillsScreen()));
      await t.pumpAndSettle();
      Finder on(String id, String text) => find.descendant(
        of: find.byKey(Key('splits_bill_row_$id')),
        matching: find.text(text),
      );
      expect(on(owe, 'You owe 10.00 USD'), findsOneWidget);
      expect(on(owed, "You're owed 10.00 USD"), findsOneWidget);
    });
  });

  group('the settle screen', () {
    Future<(SplitsController, String)> settle(
      WidgetTester t,
      List<Map<String, dynamic>> Function(SplitsController c) peer, {
      Future<void> Function(SplitsController c, String id)? then,
    }) async {
      final c = controllerWith();
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
        await c.accept(id, peer(c));
        await then?.call(c, id);
        await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
        await closeForSettling(c, id);
      });
      expect(c.lastError, isNull);
      await t.pumpWidget(host(c, SettleScreen(billId: id)));
      await t.pumpAndSettle();
      return (c, id);
    }

    testWidgets('an overpayment is not called a refund', (t) async {
      // This device paid 20.00 for itself and Ben; Ben pays it back 30.00,
      // which it confirms. It now owes Ben 20.00 that no debt explains, and
      // the bill holds no refund.
      final ben = otherHost('ben');
      final (c, _) = await settle(
        t,
        (c) => [
          entries.joinBill(
            host: ben,
            name: 'Ben',
            payTo: 'u1benpayable0000000001',
          ),
        ],
        then: (c, id) async {
          await c.addExpense(
            billId: id,
            paidBy: c.me,
            amountMinorUnits: 2000,
            among: [c.me, 'ben'],
            description: 'Dinner',
          );
          await c.accept(id, [
            entries.recordPayment(
              host: ben,
              paymentId: 'p1',
              to: c.me,
              amount: 3000,
              method: 'cash',
            ),
          ]);
          final paymentId = c.bills.single.bill.payments.single.id;
          await c.confirmPayment(
            billId: id,
            paymentId: paymentId,
            method: 'recipientConfirmed',
          );
        },
      );
      expect(c.bills.single.bill.expenses.every((e) => e.amount > 0), isTrue);
      final line = t.widget<Text>(
        find.byKey(const Key('splits_settle_unexplained_ben')),
      );
      expect(line.data, isNot(contains('refund')));
      expect(line.data, startsWith(_unexplained));
    });

    testWidgets('control: a refund the bill holds is named as one', (t) async {
      final (_, _) = await settle(
        t,
        (c) => [
          entries.joinBill(
            host: otherHost('ben'),
            name: 'Ben',
            payTo: 'u1benpayable0000000001',
          ),
          entries.addExpense(
            host: otherHost('ben'),
            expenseId: 'x1',
            paidBy: c.me,
            amount: -3000,
            split: const <String, dynamic>{
              'type': 'equal',
              'among': ['ben'],
            },
          ),
        ],
      );
      final line = t.widget<Text>(
        find.byKey(const Key('splits_settle_unexplained_ben')),
      );
      expect(line.data, contains('A refund entered by Ben'));
    });

    testWidgets('a name wraps between words beside an 8-digit figure at '
        '320@2.0', (t) async {
      await fonts();
      await setSize(t, 320, 3.0, scale: 2.0);
      final c = controllerWith();
      late String id;
      await t.runAsync(
        () async => id = await owing(c, [
          (
            id: 'pr1',
            name: 'Priyanka Ramachandran',
            address: ua('pr1'),
            owe: 12345678,
          ),
        ]),
      );
      final seen = await overflows(() async {
        await t.pumpWidget(host(c, SettleScreen(billId: id)));
        await t.pumpAndSettle();
      });
      expect(seen, isEmpty);
      final row = find.byKey(const Key('splits_settle_pay_pr1'));
      final title = paragraph(t, row, 'You → Priyanka Ramachandran');
      expect(brokenWords(title), isEmpty);
      final figure = paragraph(t, row, formatAmount(12345678, 'USD'));
      expect(brokenWords(figure), isEmpty);
    });
  });

  group('the swap screen', () {
    testWidgets('an unjoined payee: says why the address needs checking', (
      t,
    ) async {
      final c = SplitsController(
        wallet: FakeWallet(),
        store: BillStore(InMemoryBillStorage()),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
        relay: const UnconfiguredSplitsRelay(),
        swaps: FakeSwaps(),
      );
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
        final ben = otherHost('ben');
        await c.accept(id, [
          entries.joinBill(
            host: ben,
            name: 'Ben',
            payouts: [
              <String, dynamic>{
                'type': 'swap',
                'asset': 'USDC',
                'chain': 'base',
                'address': '0xben',
              },
            ],
          ),
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
        await closeForSettling(c, id);
      });
      expect(c.bills.single.identities.bound.containsKey('ben'), isFalse);
      await t.pumpWidget(
        host(c, SwapScreen(billId: id, to: 'ben', amountMinorUnits: 1000)),
      );
      await t.pumpAndSettle();
      expect(
        t.widget<Text>(find.byKey(const Key('splits_swap_unbound_ben'))).data,
        'Ben hasn’t joined on their phone. Check this address with them.',
      );
    });
  });
}
