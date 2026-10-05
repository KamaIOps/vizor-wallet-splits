// Two closes in flight at once — a double tap, or two of the creator's
// devices — are two closes over one set of expenses. §10.9's latest close
// decides, so one Reopen opens the bill.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// A clock that moves on every read, as a real one does between two taps.
class _MovingWallet extends FakeWallet {
  DateTime _t = DateTime.utc(2026, 10, 28, 19, 30);
  @override
  DateTime now() => _t = _t.add(const Duration(milliseconds: 250));
}

Future<(SplitsController, String)> _bill() async {
  final c = SplitsController(
    wallet: _MovingWallet(),
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  );
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benpayable0000000001'),
    entries.addExpense(
      host: ben,
      expenseId: 'hotel',
      paidBy: 'ben',
      amount: 2000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['ben', c.me]..sort(),
      },
    ),
  ]);
  return (c, id);
}

void main() {
  test('one close, one reopen, the bill is open', () async {
    final (c, id) = await _bill();
    await c.closeForSettling(id);
    await c.reopen(id);
    final closed = c.bills.single.folded!.closed;
    expect(closed, isFalse);
  });

  test('two closes in flight, one reopen, and an expense is written', () async {
    final (c, id) = await _bill();
    await Future.wait([c.closeForSettling(id), c.closeForSettling(id)]);
    expect(
      c.bills.single.activity.where(
        (e) => e.kind == BillEventKind.closedForSettling,
      ),
      hasLength(2),
      reason: 'both closes were written',
    );
    expect(c.bills.single.folded!.closed, isTrue);
    await c.reopen(id);
    expect(c.bills.single.folded!.closed, isFalse);
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 100,
      among: ['ben', c.me],
      description: 'fix',
    );
    expect(c.lastError, isNull);
    expect(c.bills.single.bill.expenses, hasLength(2));
  });
}
