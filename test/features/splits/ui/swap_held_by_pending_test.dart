// §14.4: a payment counts first against its own payee's settlement. Paying
// Zed exactly what his settlement asks holds nothing else back, so the swap to
// Ben goes straight after it. Paying Zed more than that is money netting may
// have moved onto Ben's debt, and that holds the swap, naming whose
// confirmation it waits on rather than saying the bill changed.

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'support/closing.dart';
import 'swap_screens_test.dart' show FakeSwaps, controllerFor;

/// This device owes Ben 10.00 and Zed 5.00, and Zed owes Ben 3.00. Netted,
/// this device pays Ben 13.00 by swap and Zed 2.00 in ZEC, and the payment to
/// Ben covers Zed's debt to him.
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
  final zed = otherHost('zed');
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
    entries.joinBill(host: zed, name: 'Zed', payTo: 'u1zedpayable0000000001'),
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
      host: zed,
      expenseId: 'tickets',
      paidBy: 'zed',
      amount: 1000,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['zed', c.me]..sort(),
      },
    ),
    entries.addExpense(
      host: ben,
      expenseId: 'fuel',
      paidBy: 'ben',
      amount: 600,
      split: <String, dynamic>{
        'type': 'equal',
        'among': ['ben', 'zed'],
      },
    ),
  ]);
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await closeForSettling(c, id);
  return (c, wallet, id);
}

void main() {
  test(
    'paying Zed exactly what he is owed leaves the swap to Ben payable',
    () async {
      final (c, wallet, id) = await _bill();
      final owed = (await c.obligation(id))!;
      expect(
        {for (final s in owed.settlements) s.to: s.amount},
        {'ben': 1300, 'zed': 200},
      );
      // The ZEC leg, through the library's own settle.
      expect((await c.settle(id, owed))!.result, entries.SendResult.sent);
      expect(wallet.sender.sent, hasLength(1));

      final quote = (await c.quoteSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1300,
      ))!;
      await c.sendSwap(
        billId: id,
        to: 'ben',
        amountMinorUnits: 1300,
        quote: quote,
      );
      expect(c.lastError, isNull);
      expect(wallet.sender.sent, hasLength(2), reason: 'the deposit is sent');
    },
  );

  test('paying Zed more than his settlement holds the swap, and the refusal '
      'names whose confirmation it waits on', () async {
    final (c, wallet, id) = await _bill();
    // 5.00 in cash: all this device owed Zed before netting, 3.00 more than
    // his settlement. That 3.00 may be the debt netting moved onto Ben's.
    await c.recordCash(billId: id, to: 'zed', amountMinorUnits: 500);
    expect(c.lastError, isNull);
    final quote = (await c.quoteSwap(
      billId: id,
      to: 'ben',
      amountMinorUnits: 1300,
    ))!;
    await c.sendSwap(
      billId: id,
      to: 'ben',
      amountMinorUnits: 1300,
      quote: quote,
    );
    expect(wallet.sender.sent, isEmpty, reason: 'no deposit is sent');
    expect(c.lastError, contains('Zed'));
    expect(c.lastError, isNot(contains('The bill changed')));
  });

  test('once that payment is confirmed, the swap goes', () async {
    final (c, wallet, id) = await _bill();
    await c.settle(id, (await c.obligation(id))!);
    final view = c.bills.single;
    final zec = view.bill.payments.single;
    await c.accept(id, [
      entries.confirmPayment(
        host: otherHost('zed'),
        paymentId: zec.id,
        method: 'recipientConfirmed',
        record: view.paymentDigests[zec.id]!,
      ),
    ]);
    final quote = (await c.quoteSwap(
      billId: id,
      to: 'ben',
      amountMinorUnits: 1300,
    ))!;
    await c.sendSwap(
      billId: id,
      to: 'ben',
      amountMinorUnits: 1300,
      quote: quote,
    );
    expect(c.lastError, isNull);
    expect(wallet.sender.sent, hasLength(2));
  });

  test('a debt nothing pending covers still says the bill changed', () async {
    final (c, wallet, id) = await _bill();
    final quote = (await c.quoteSwap(
      billId: id,
      to: 'ben',
      amountMinorUnits: 1300,
    ))!;
    // A different amount than the one owed: not held, just not this debt.
    await c.sendSwap(
      billId: id,
      to: 'ben',
      amountMinorUnits: 1200,
      quote: quote,
    );
    expect(wallet.sender.sent, isEmpty);
    expect(c.lastError, contains('The bill changed'));
  });
}
