/// An entry the fold would set aside is refused before it is written.
///
/// Written and then refused, it stays in the log, reaches every device on the
/// next sync, and is reported there as set aside for good: a typo in a split
/// becomes a permanent line on everybody's bill.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// A bill this device opened, with Ben and Cleo on it, Ben having paid 20.00
/// split three ways and recorded paying Cleo 1.00 in cash.
Future<(SplitsController, String)> _bill() async {
  final c = SplitsController(
    wallet: FakeWallet(),
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(7)),
  );
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final ben = otherHost('ben');
  final cleo = otherHost('cleo');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben'),
    entries.joinBill(host: cleo, name: 'Cleo'),
    entries.addExpense(
      host: ben,
      expenseId: 'hotel',
      paidBy: 'ben',
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['ben', 'cleo', c.me]..sort(),
      },
    ),
    entries.recordPayment(
      host: ben,
      paymentId: 'p-cleo',
      to: 'cleo',
      amount: 100,
      method: 'cash',
    ),
  ]);
  return (c, id);
}

BillView _view(SplitsController c, String id) =>
    c.bills.singleWhere((b) => b.id == id);

/// Runs [action], which must be refused, and checks nothing reached the log.
Future<String?> _refusedUnwritten(
  SplitsController c,
  String id,
  Future<void> Function() action,
) async {
  final before = _view(c, id).entryCount;
  final failure = await c.failureOf(action);
  expect(failure, isNotNull, reason: 'the entry is refused');
  expect(_view(c, id).entryCount, before, reason: 'and never written');
  expect(_view(c, id).setAside, isEmpty, reason: 'so nothing is set aside');
  return failure;
}

void main() {
  test('an exact split that misses the total is refused unwritten', () async {
    final (c, id) = await _bill();
    final said = await _refusedUnwritten(
      c,
      id,
      () => c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 300,
        split: {
          'type': 'exact',
          'amounts': {c.me: 200, 'ben': 90},
        },
      ),
    );
    expect(said, contains('add up'));
  });

  test('every kind of refusal is kept out of the log', () async {
    final (c, id) = await _bill();
    // percentage_not_full_scale
    await _refusedUnwritten(
      c,
      id,
      () => c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 300,
        split: {
          'type': 'percentage',
          'basisPoints': {c.me: 5000, 'ben': 4000},
        },
      ),
    );
    // itemized_unassigned_item
    await _refusedUnwritten(
      c,
      id,
      () => c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 90,
        split: {
          'type': 'itemized',
          'extraMinorUnits': 0,
          'items': [
            {
              'description': 'taxi',
              'minorUnits': 60,
              'sharedBy': [c.me],
            },
            {'description': 'snacks', 'minorUnits': 30, 'sharedBy': <String>[]},
          ],
        },
      ),
    );
    // self_payment
    await _refusedUnwritten(
      c,
      id,
      () => c.recordCash(billId: id, to: c.me, amountMinorUnits: 10),
    );
    // unauthorized_confirmation: Ben paid Cleo, not this device
    await _refusedUnwritten(
      c,
      id,
      () => c.confirmPayment(
        billId: id,
        paymentId: 'p-cleo',
        method: 'recipientConfirmed',
      ),
    );
    // unauthorized_entry: only its author amends an expense, and the creator
    // is not Ben (the creator may withdraw it, which is §10.8's other rule).
    await _refusedUnwritten(
      c,
      id,
      () => c.editExpense(
        billId: id,
        entryId: _view(
          c,
          id,
        ).expenseEntries[_view(c, id).bill.expenses.single.id]!,
        amountMinorUnits: 2100,
      ),
    );
  });

  test(
    'an entry naming somebody not yet synced is written, and said',
    () async {
      // Their join may be on its way: the entry applies once it arrives, so it
      // is kept, and the person is still told it does not apply yet.
      final (c, id) = await _bill();
      final before = _view(c, id).entryCount;
      final failure = await c.failureOf(
        () => c.addExpense(
          billId: id,
          paidBy: c.me,
          amountMinorUnits: 300,
          among: [c.me, 'dana'],
        ),
      );
      expect(failure, isNotNull);
      expect(_view(c, id).entryCount, before + 1);
      expect(
        _view(c, id).setAside.map((a) => a.code),
        contains('unknown_participant'),
      );
    },
  );

  test('an entry that applies is still written', () async {
    final (c, id) = await _bill();
    final before = _view(c, id).entryCount;
    final failure = await c.failureOf(
      () => c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 300,
        split: {
          'type': 'exact',
          'amounts': {c.me: 200, 'ben': 100},
        },
        description: 'Tickets',
      ),
    );
    expect(failure, isNull);
    expect(_view(c, id).entryCount, before + 1);
    final tickets = _view(
      c,
      id,
    ).bill.expenses.singleWhere((e) => e.description == 'Tickets');
    // And this device's own expense may be withdrawn.
    expect(
      await c.failureOf(
        () => c.withdraw(
          billId: id,
          entryId: _view(c, id).expenseEntries[tickets.id]!,
        ),
      ),
      isNull,
    );
    expect(_view(c, id).entryCount, before + 2);
    expect(_view(c, id).setAside, isEmpty);
  });
}
