// §10.9 and §14.9 through the wallet: nobody pays until the creator closes the
// bill, nobody changes an expense while it is closed, and every refusal says
// who can unblock it.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps, controllerFor;

/// A device on [relay], so two of them share one bill.
SplitsController controllerForRelay(
  FakeWallet wallet,
  SplitsRelay relay,
  int seed,
) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(seed)),
  relay: relay,
);

/// This device opened the bill; Ben paid 20.00 split with it, and Cai, paid
/// in USDC, paid 10.00 split with it. It owes Ben 10.00 and Cai 5.00.
Future<(SplitsController, FakeWallet, String)> _bill() async {
  final wallet = FakeWallet(
    outcome: const WalletSendOutcome(
      phase: WalletSendPhase.succeeded,
      txid: 'tx-1',
    ),
  );
  final c = controllerFor(wallet, swaps: FakeSwaps());
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final ben = otherHost('ben');
  final cai = otherHost('cai');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benpayable0000000001'),
    entries.joinBill(
      host: cai,
      name: 'Cai',
      payouts: [
        <String, dynamic>{
          'type': 'swap',
          'asset': 'USDC',
          'chain': 'base',
          'address': '0xcai',
        },
      ],
    ),
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
    entries.addExpense(
      host: cai,
      expenseId: 'cab',
      paidBy: 'cai',
      amount: 1000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['cai', c.me]..sort(),
      },
    ),
  ]);
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  return (c, wallet, id);
}

void main() {
  test('an open bill pays nothing, by any way of paying', () async {
    final (c, wallet, id) = await _bill();
    final owed = (await c.obligation(id))!;
    await c.settle(id, owed);
    expect(c.lastError, contains('Close the bill for settling'));
    await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
    expect(c.lastError, contains('Close the bill for settling'));
    final quote = (await c.quoteSwap(
      billId: id,
      to: 'cai',
      amountMinorUnits: 500,
    ))!;
    await c.sendSwap(
      billId: id,
      to: 'cai',
      amountMinorUnits: 500,
      quote: quote,
    );
    expect(c.lastError, contains('Close the bill for settling'));
    await c.recordSwap(
      billId: id,
      reference: 'swap-1',
      to: 'cai',
      amountMinorUnits: 500,
    );
    expect(c.lastError, contains('Close the bill for settling'));
    expect(wallet.sender.sent, isEmpty, reason: 'nothing reached the wallet');
    expect(c.bills.single.bill.payments, isEmpty);
  });

  test('closed, every way of paying goes through', () async {
    final (c, wallet, id) = await _bill();
    await c.closeForSettling(id);
    expect(c.lastError, isNull);
    expect(c.bills.single.folded!.closed, isTrue);
    expect(
      (await c.settle(id, (await c.obligation(id))!))!.result.name,
      'sent',
    );
    final quote = (await c.quoteSwap(
      billId: id,
      to: 'cai',
      amountMinorUnits: 500,
    ))!;
    await c.sendSwap(
      billId: id,
      to: 'cai',
      amountMinorUnits: 500,
      quote: quote,
    );
    expect(c.lastError, isNull);
    expect(
      wallet.sender.sent,
      hasLength(2),
      reason: 'the request and the swap',
    );
  });

  test('closed, no expense is added, corrected or taken off; a payment record '
      'still is', () async {
    final (c, _, id) = await _bill();
    await c.closeForSettling(id);
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 600,
      among: [c.me, 'ben'],
    );
    expect(c.lastError, contains('Reopen it to change expenses'));
    final hotel = c.bills.single.expenseEntries.values.first;
    await c.withdraw(billId: id, entryId: hotel);
    expect(c.lastError, contains('Reopen it to change expenses'));
    expect(c.bills.single.bill.expenses, hasLength(2));

    await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
    expect(c.lastError, isNull);
    final cash = c.bills.single.paymentEntries.values.single;
    await c.withdraw(billId: id, entryId: cash);
    expect(c.lastError, isNull, reason: 'a payment record is not an expense');
    expect(c.bills.single.bill.payments, isEmpty);
  });

  test(
    'reopened, an expense is written, and the bill must be closed again',
    () async {
      final (c, _, id) = await _bill();
      await c.closeForSettling(id);
      await c.reopen(id);
      expect(c.bills.single.folded!.closed, isFalse);
      await c.addExpense(
        billId: id,
        paidBy: c.me,
        amountMinorUnits: 600,
        among: [c.me, 'ben'],
      );
      expect(c.lastError, isNull);
      await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 700);
      expect(c.lastError, contains('Close the bill for settling'));
      await c.closeForSettling(id);
      await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 700);
      expect(c.lastError, isNull);
    },
  );

  test(
    'a peer\'s expense written after the close reopens it here too',
    () async {
      final (c, _, id) = await _bill();
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
      expect(c.bills.single.folded!.closed, isFalse);
      await c.recordCash(billId: id, to: 'ben', amountMinorUnits: 1000);
      expect(c.lastError, contains('Close the bill for settling'));
    },
  );

  test('the honest path is never refused: somebody added by mistake taken '
      'off, an expense corrected, closed, reopened for a correction, closed '
      'again, and everything paid in one send', () async {
    final (c, wallet, id) = await _bill();
    await c.accept(id, [
      entries.joinBill(
        host: otherHost('dee'),
        name: 'Dee',
        payTo: 'u1deepayable0000000001',
      ),
    ]);
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 600,
      among: [c.me, 'dee'],
    );
    expect(c.lastError, isNull);
    String mine() => c.bills.single.expenseEntries.entries
        .singleWhere(
          (e) =>
              c.bills.single.bill.expenses
                  .singleWhere((x) => x.id == e.key)
                  .paidBy ==
              c.me,
        )
        .value;
    await c.editExpense(billId: id, entryId: mine(), amountMinorUnits: 800);
    expect(c.lastError, isNull);

    await c.removePerson(billId: id, id: 'dee');
    expect(c.lastError, isNull);
    expect(c.bills.single.bill.participant('dee'), isNull);

    await c.closeForSettling(id);
    await c.reopen(id);
    expect(c.lastError, isNull);
    await c.editExpense(billId: id, entryId: mine(), amountMinorUnits: 900);
    expect(c.lastError, isNull);
    await c.closeForSettling(id);
    expect(c.bills.single.folded!.closed, isTrue);

    final owed = (await c.obligation(id))!;
    final quote = (await c.quoteSwap(
      billId: id,
      to: 'cai',
      amountMinorUnits: 500,
    ))!;
    await c.settleWithSwap(
      billId: id,
      owed: owed,
      to: 'cai',
      amountMinorUnits: 500,
      quote: quote,
    );
    expect(c.lastError, isNull);
    expect(wallet.sender.sent, hasLength(1));
    final left = (await c.obligation(id))!;
    expect(left.carriedTo, isEmpty);
    expect(left.unpayable, isEmpty);
    expect(c.bills.single.folded!.setAside, isEmpty);
  });

  test('somebody who did not open the bill can neither close nor reopen it, '
      'and is told who can', () async {
    final relay = InMemorySplitsRelay();
    final anaWallet = FakeWallet();
    final benWallet = FakeWallet(id: 'ben', payTo: 'u1ben');
    final ana = controllerForRelay(anaWallet, relay, 1);
    final ben = controllerForRelay(benWallet, relay, 2);
    await ana.load();
    await ben.load();
    final id = (await ana.createBill(name: 'Trip', currency: 'USD'))!;
    await ana.join(id, displayName: 'Ana');
    await ben.acceptKey(id, await ana.billKey(id));
    await ana.syncBill(id);
    await ben.syncBill(id);
    await ben.join(id, displayName: 'Ben');
    await ben.syncBill(id);

    await ben.closeForSettling(id);
    expect(ben.lastError, isNotNull);
    expect(ben.bills.single.folded!.closed, isFalse);
    await ben.recordCash(billId: id, to: ana.me, amountMinorUnits: 100);
    expect(ben.lastError, 'Waiting for Ana to close the bill for settling.');

    await ana.syncBill(id);
    await ana.closeForSettling(id);
    await ana.syncBill(id);
    await ben.syncBill(id);
    expect(ben.bills.single.folded!.closed, isTrue);
    await ben.reopen(id);
    expect(ben.lastError, isNotNull);
    expect(ben.bills.single.folded!.closed, isTrue);
    await ben.addExpense(
      billId: id,
      paidBy: ben.me,
      amountMinorUnits: 600,
      among: [ana.me, ben.me],
    );
    expect(
      ben.lastError,
      'The bill is closed for settling. Ask Ana to reopen it.',
    );
  });
}
