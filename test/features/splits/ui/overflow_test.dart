/// Every screen fits the narrow phones, at every screen.
///
/// A `RenderFlex` that overflows hides content: the yellow-and-black stripe is
/// the only thing that says so, and on a device the lane that drives the
/// screens tolerates it, so nothing fails. The widths below are the logical
/// widths of the phones this ships to; the names and figures are deliberately
/// long, because a participant nobody has renamed is named by its id.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

String _where(FlutterErrorDetails d) {
  final parts = <String>[d.context?.toDescription() ?? ''];
  for (final n in d.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
    final s = n.toStringDeep().trim().replaceAll('\n', ' ');
    if (s.isNotEmpty) parts.add(s);
  }
  return parts.where((p) => p.isNotEmpty).join('  ::  ');
}

void main() {
  for (final width in <double>[402, 393, 375]) {
    testWidgets('screens at ${width.toInt()}px', (t) async {
      t.view.physicalSize = Size(width * 3, 874 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);

      final hits = <String>[];
      final overflowed = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final e = d.exception;
        if (e is FlutterError && e.toString().contains('overflowed')) {
          hits.add('${e.message.split('\n').first}  <<<  ${_where(d)}');
          return;
        }
        previous?.call(d);
      };
      addTearDown(() => FlutterError.onError = previous);

      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(
        name: 'Dinner in Lisbon',
        currency: 'EUR',
      ))!;
      await c.addPerson(
        billId: id,
        id: 'priyanka',
        name: 'Priyanka Raghunathan',
      );
      await c.addPerson(billId: id, id: 'bart', name: 'Bartholomew');
      await c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 6000,
        split: const {'type': 'equal'},
        description: 'Covered',
      );

      for (final entry in <String, Widget Function()>{
        'BillsScreen': () => const BillsScreen(),
        'BillScreen': () => BillScreen(billId: id),
        'PeopleScreen': () => PeopleScreen(billId: id),
        'PayoutScreen': () => PayoutScreen(billId: id),
        'SettleScreen': () => SettleScreen(billId: id),
        'ActivityScreen': () => ActivityScreen(billId: id),
        'AddExpenseScreen': () => AddExpenseScreen(billId: id),
        'NewBillScreen': () => const NewBillScreen(),
        'PriceBillScreen': () => PriceBillScreen(billId: id),
        'ShareBillScreen': () => ShareBillScreen(billId: id),
        'ScanBillScreen': () => const ScanBillScreen(),
        'RecordPaymentScreen': () =>
            RecordPaymentScreen(billId: id, to: 'priyanka'),
        'SwapScreen': () =>
            SwapScreen(billId: id, to: 'priyanka', amountMinorUnits: 3000),
      }.entries) {
        hits.clear();
        await t.pumpWidget(app(c, entry.value()));
        await t.pumpAndSettle();
        for (final h in hits) {
          debugPrint('OVERFLOW ${width.toInt()} ${entry.key}: $h');
          overflowed.add(
            '${entry.key} at ${width.toInt()}px: '
            '${h.split('  <<<  ').first}',
          );
        }
      }

      expect(
        overflowed,
        isEmpty,
        reason: 'these screens hide content at this width',
      );
    });
  }
}
