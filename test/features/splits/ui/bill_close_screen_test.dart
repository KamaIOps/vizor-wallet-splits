// §14.9 on the bill screen: the creator closes the bill for settling, Settle up
// opens only once it is closed, Add expense closes with it, and an expense
// that arrives afterwards is said to have reopened it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'entry_join_test.dart' show ctl, take;
import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps, app, controllerFor;

Future<(SplitsController, String)> _bill(WidgetTester t) async {
  final c = controllerFor(FakeWallet(), swaps: FakeSwaps());
  late String id;
  await t.runAsync(() async {
    await c.load();
    id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    await c.accept(id, [
      entries.joinBill(
        host: otherHost('ben'),
        name: 'Ben',
        payTo: 'u1benpayable0000000001',
      ),
      entries.addExpense(
        host: otherHost('ben'),
        expenseId: 'hotel',
        paidBy: 'ben',
        amount: 2000,
        split: <String, dynamic>{
          'type': 'equal',
          'among': ['ben', c.me]..sort(),
        },
      ),
    ]);
  });
  return (c, id);
}

/// Whether the button keyed [key] can be pressed.
bool _enabled(WidgetTester t, String key) {
  final inside = find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );
  final target = _buttonOf(t, key, inside);
  return target.onPressed != null;
}

ButtonStyleButton _buttonOf(WidgetTester t, String key, Finder inside) {
  final own = t.widget(find.byKey(Key(key)));
  if (own is ButtonStyleButton) return own;
  return t.widget<ButtonStyleButton>(inside.first);
}

void main() {
  testWidgets('the creator closes it, and only then is it settled', (t) async {
    final (c, id) = await _bill(t);
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_bill_close')), findsOneWidget);
    expect(find.byKey(const Key('splits_bill_settle')), findsNothing);
    expect(_enabled(t, 'splits_bill_add_expense'), isTrue);

    await t.tap(find.byKey(const Key('splits_bill_close')));
    await t.pumpAndSettle();
    expect(find.text('Close for settling?'), findsOneWidget);
    // An expense from a phone that had not seen the close still lands.
    expect(find.textContaining('reopens it until you close'), findsOneWidget);
    await t.tap(find.byKey(const Key('splits_bill_close_confirm')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await t.pumpAndSettle();

    expect(c.bills.single.folded!.closed, isTrue);
    expect(
      find.byKey(const Key('splits_bill_closed_notice')),
      findsNothing,
      reason: 'the creator is not told what they just did',
    );
    expect(_enabled(t, 'splits_bill_settle'), isTrue);
    expect(_enabled(t, 'splits_bill_add_expense'), isFalse);

    await t.tap(find.byKey(const Key('splits_bill_menu')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_bill_reopen')), findsOneWidget);
  });

  testWidgets('"Not yet" closes nothing', (t) async {
    final (c, id) = await _bill(t);
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_bill_close')));
    await t.pumpAndSettle();
    await t.tap(find.text('Not yet'));
    await t.pumpAndSettle();
    expect(c.bills.single.folded!.closed, isFalse);
    expect(find.byKey(const Key('splits_bill_close')), findsOneWidget);
  });

  testWidgets('an expense that arrives after the close is said to have '
      'reopened it', (t) async {
    final (c, id) = await _bill(t);
    await t.runAsync(() async {
      await c.closeForSettling(id);
      await c.accept(id, [
        entries.addExpense(
          host: otherHost('ben'),
          expenseId: 'taxi',
          paidBy: 'ben',
          amount: 400,
          split: <String, dynamic>{
            'type': 'equal',
            'among': ['ben', c.me]..sort(),
          },
        ),
      ]);
    });
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_bill_reopened')), findsOneWidget);
    expect(find.byKey(const Key('splits_bill_close')), findsOneWidget);
  });

  testWidgets('withdrawn by the creator, it is open and not said to have been '
      'reopened by a change', (t) async {
    final (c, id) = await _bill(t);
    await t.runAsync(() async {
      await c.closeForSettling(id);
      await c.reopen(id);
    });
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_bill_reopened')), findsNothing);
    expect(find.byKey(const Key('splits_bill_close')), findsOneWidget);
  });

  /// Ana's bill as this device takes it from her code and joins it, closed
  /// by her first when [closed].
  Future<(SplitsController, String)> anas(
    WidgetTester t, {
    required bool closed,
    bool join = true,
  }) async {
    final c = ctl(
      FakeWallet(id: 'cai', payTo: 'u1caipayable0000000001'),
      seed: 7,
    );
    late String id;
    await t.runAsync(() async {
      final ana = ctl(FakeWallet(), seed: 1);
      await ana.load();
      id = (await ana.createBill(name: 'Trip', currency: 'USD'))!;
      await ana.join(id, displayName: 'Ana');
      if (closed) await ana.closeForSettling(id);
      final code = (await ana.shareableBill(id))!;
      await c.load();
      await take(c, code);
      if (join) await c.join(id, displayName: 'Cai');
      expect(c.lastError, isNull);
    });
    return (c, id);
  }

  testWidgets('somebody else on an open bill is told who closes it', (t) async {
    final (c, id) = await anas(t, closed: false);
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(_enabled(t, 'splits_bill_settle'), isFalse);
    final notice = find.byKey(const Key('splits_bill_open_notice'));
    expect(notice, findsOneWidget);
    expect(
      find.descendant(of: notice, matching: find.textContaining('Ana')),
      findsOneWidget,
    );
  });

  testWidgets('once closed, the open notice gives way to who closed it', (
    t,
  ) async {
    final (c, id) = await anas(t, closed: true);
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_bill_open_notice')), findsNothing);
    expect(find.byKey(const Key('splits_bill_closed_notice')), findsOneWidget);
  });

  testWidgets('the creator is not told to wait for themselves', (t) async {
    final (c, id) = await _bill(t);
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_bill_open_notice')), findsNothing);
  });

  testWidgets('joining says it shares this wallet’s address', (t) async {
    final (c, id) = await anas(t, closed: false, join: false);
    await t.pumpWidget(app(c, BillScreen(billId: id)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_bill_join')), findsOneWidget);
    expect(find.byKey(const Key('splits_bill_join_shares')), findsOneWidget);

    await t.pumpWidget(app(c, const ScanBillScreen()));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('splits_scan_join_shares')), findsOneWidget);
  });
}
