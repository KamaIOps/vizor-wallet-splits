// A combined send (§14.10) — one transaction paying Ben in ZEC and Cai's
// swap deposit — left unresolved by a kill before the wallet named the
// transaction. The card must take the transaction id, and a refused "It went
// through" must leave nothing written.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps;

const _noTxid = WalletSendOutcome(
  phase: WalletSendPhase.pendingBroadcast,
  statusMessage: 'created, not broadcast',
);

const _tx = 'abababababababababababababababababababababababababababababababab';

/// This device owes Ben 10.00, paid in ZEC, and Cai 5.00, paid in USDC on
/// Base, closed for settling. The wallet never names the transaction.
/// Without [owesBen], only Cai is owed.
Future<(SplitsController, String)> _bill({bool owesBen = true}) async {
  final c = SplitsController(
    wallet: FakeWallet(outcome: _noTxid),
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
    relay: const UnconfiguredSplitsRelay(),
    swaps: FakeSwaps(),
    own: () async => const [],
  );
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
    for (final (who, host, x, amount) in [
      if (owesBen) ('ben', ben, 'hotel', 2000),
      ('cai', cai, 'cab', 1000),
    ])
      entries.addExpense(
        host: host,
        expenseId: x,
        paidBy: who,
        amount: amount,
        split: <String, dynamic>{
          'type': 'equal',
          'among': [who, c.me]..sort(),
        },
      ),
  ]);
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await c.closeForSettling(id);
  return (c, id);
}

/// Sends Ben's ZEC and Cai's swap in one transaction, leaving the note.
Future<void> _combined(SplitsController c, String id) async {
  final owed = (await c.obligation(id))!;
  await c.settleWithSwap(
    billId: id,
    owed: owed,
    to: 'cai',
    amountMinorUnits: 500,
    quote: (await c.quoteSwap(billId: id, to: 'cai', amountMinorUnits: 500))!,
  );
  final note = (await c.pendingSend(id))!;
  expect(note.txid, isNull);
  expect(note.swap, isNotNull);
  expect(note.sent, isNotEmpty);
}

Future<List<String>> _paid(SplitsController c, String id) async => [
  for (final p in (await c.currentView(id))!.bill.payments)
    '${p.to}:${p.method}',
]..sort();

Future<void> _open(WidgetTester t, SplitsController c, String id) async {
  await t.pumpWidget(
    SplitsScope(
      controller: c,
      child: MaterialApp(home: SettleScreen(billId: id)),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _wentThrough(WidgetTester t) async {
  final record = find.byKey(const Key('splits_pending_record'));
  await t.ensureVisible(record);
  await t.tap(record);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the card takes the transaction id and records both halves', (
    t,
  ) async {
    final (c, id) = await _bill();
    await _combined(c, id);
    await _open(t, c, id);
    final field = find.byKey(const Key('splits_pending_txid'));
    expect(field, findsOneWidget);
    await t.enterText(field, _tx);
    await _wentThrough(t);
    expect(c.lastError, isNull);
    expect(await _paid(c, id), ['ben:shieldedZec', 'cai:swap']);
    expect(await c.pendingSend(id), isNull);
  });

  testWidgets('with no id given, it is refused and nothing is written', (
    t,
  ) async {
    final (c, id) = await _bill();
    await _combined(c, id);
    await _open(t, c, id);
    await _wentThrough(t);
    expect(c.lastError, contains('transaction id'));
    expect(await _paid(c, id), isEmpty);
    expect(await c.pendingSend(id), isNotNull);
  });

  test('a text that is not a transaction id writes nothing either', () async {
    final (c, id) = await _bill();
    await _combined(c, id);
    await c.resolveSend(id, landed: true, txid: 'not-a-txid');
    expect(c.lastError, contains('Not a transaction id'));
    expect(await _paid(c, id), isEmpty);
    expect(await c.pendingSend(id), isNotNull);
    // The same note then records with the right one.
    await c.resolveSend(id, landed: true, txid: _tx.toUpperCase());
    expect(c.lastError, isNull);
    expect(await _paid(c, id), ['ben:shieldedZec', 'cai:swap']);
  });

  testWidgets('a swap sent alone still asks for no transaction id', (t) async {
    final (c, id) = await _bill(owesBen: false);
    await c.sendSwap(
      billId: id,
      to: 'cai',
      amountMinorUnits: 500,
      quote: (await c.quoteSwap(billId: id, to: 'cai', amountMinorUnits: 500))!,
    );
    final note = (await c.pendingSend(id))!;
    expect(note.sent, isEmpty);
    await _open(t, c, id);
    expect(find.byKey(const Key('splits_pending_txid')), findsNothing);
    await _wentThrough(t);
    expect(c.lastError, isNull);
    expect(await _paid(c, id), ['cai:swap']);
  });
}
