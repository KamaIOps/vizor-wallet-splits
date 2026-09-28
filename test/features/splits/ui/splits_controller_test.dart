import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(
  FakeWallet wallet, {
  SplitsRelay relay = const UnconfiguredSplitsRelay(),
  int seed = 1,
  SplitsKeys? keys,
}) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: keys ?? SplitsKeys(store: InMemorySecretStore(), random: Random(seed)),
  relay: relay,
);

void main() {
  test('opening a bill joins it in the same breath', () async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    await c.load();
    expect(c.identityKey, isNotNull);
    expect(c.identityIsRecoverable, isTrue);

    final id = await c.createBill(name: 'Dinner', currency: 'EUR');
    expect(c.lastError, isNull);
    expect(id, isNotNull);

    final bill = c.bills.single;
    expect(bill.id, id);
    expect(bill.bill.name, 'Dinner');
    expect(bill.creatorId, c.me);
    expect(bill.bill.participants.single.id, c.me);
    expect(bill.setAside, isEmpty);
    // §10.7: a device that signs speaks as the id its key derives, not as the
    // account's own handle.
    expect(c.me, splitz.participantId(c.identityKey!));
    expect(c.me, isNot('ana'));

    // §10.7 binds the creator by the key the bill's own id commits to.
    expect(bill.identities.bound[c.me], c.identityKey);
  });

  test('an expense splits, and both people see the same numbers', () async {
    final relay = InMemorySplitsRelay();
    final anaWallet = FakeWallet();
    final benWallet = FakeWallet(id: 'ben', payTo: 'u1ben');
    final ana = controllerFor(anaWallet, relay: relay, seed: 1);
    final ben = controllerFor(benWallet, relay: relay, seed: 2);
    await ana.load();
    await ben.load();

    final id = (await ana.createBill(name: 'Dinner', currency: 'EUR'))!;

    // Ben scans the invite: he gets the bill id and its key.
    await ben.acceptKey(id, await ana.billKey(id));
    await ana.syncBill(id);
    await ben.syncBill(id);
    await ben.join(id, displayName: 'Ben');
    await ben.syncBill(id);
    await ana.syncBill(id);

    anaWallet.tick();
    await ana.addExpense(
      billId: id,
      paidBy: ana.me,
      amountMinorUnits: 9000,
      among: [ana.me, ben.me],
      description: 'Dinner',
    );
    expect(ana.lastError, isNull);
    await ana.syncBill(id);
    await ben.syncBill(id);

    final here = ana.bills.single.bill;
    final there = ben.bills.single.bill;
    expect(
      protocol.netBalances(here),
      protocol.netBalances(there),
      reason: 'two devices holding one entry set owe the same money',
    );
    expect(protocol.netBalances(here)[ana.me], 4500);
    expect(protocol.netBalances(here)[ben.me], -4500);
  });

  test(
    'a priced bill produces one request that carries the whole debt',
    () async {
      final relay = InMemorySplitsRelay();
      final anaWallet = FakeWallet();
      final benWallet = FakeWallet(id: 'ben', payTo: 'u1ben');
      final ana = controllerFor(anaWallet, relay: relay, seed: 1);
      final ben = controllerFor(benWallet, relay: relay, seed: 2);
      await ana.load();
      await ben.load();

      final id = (await ana.createBill(name: 'Dinner', currency: 'EUR'))!;
      await ben.acceptKey(id, await ana.billKey(id));
      await ana.syncBill(id);
      await ben.syncBill(id);
      await ben.join(id, displayName: 'Ben');
      await ben.syncBill(id);

      anaWallet.tick();
      await ana.addExpense(
        billId: id,
        paidBy: ana.me,
        amountMinorUnits: 9000,
        among: [ana.me, ben.me],
      );
      anaWallet.tick();
      await ana.setRate(billId: id, currency: 'EUR', minorUnitsPerZec: 51234);
      await ana.syncBill(id);
      await ben.syncBill(id);

      // Ana is owed, so ana owes nothing.
      expect((await ana.obligation(id))!.settlements, isEmpty);

      final owed = (await ben.obligation(id))!;
      expect(owed.settlements.single.to, ana.me);
      expect(owed.settlements.single.amount, 4500);
      expect(owed.isComplete, isTrue);
      expect(owed.uri, startsWith('zcash:u1ana'));

      // §10.5 gives every recipient of one transaction its own payment id, so
      // the id is the transaction and the payee, and the transaction itself is
      // the reference. One transaction paying two people writes two records
      // that the fold keeps apart.
      final settled = await ben.settle(id, owed);
      expect(settled!.result, splitz.SendResult.sent);
      expect(
        settled.records.single['payment']['id'],
        '${settled.txid}:${ana.me}',
      );
      expect(settled.records.single['payment']['reference'], settled.txid);

      // §10.5: a record is a claim. The debt does not move until it is confirmed.
      expect(protocol.netBalances(ben.bills.single.bill)[ben.me], -4500);

      // And asking again does not ask for the same money twice.
      final again = (await ben.obligation(id))!;
      expect(again.settlements, isEmpty);
      expect(again.awaiting.single.to, ana.me);
    },
  );

  test(
    'an unpriced bill has nothing to send, and that is not an error',
    () async {
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
      expect(await c.obligation(id), isNull);
      expect(c.lastError, isNull);
    },
  );

  test('a failure is reported rather than swallowed', () async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;

    // No relay in this build: a push cannot silently do nothing.
    await c.syncBill(id);
    expect(c.lastError, contains('no bill relay'));

    // And the next action clears it.
    await c.setRate(billId: id, currency: 'EUR', minorUnitsPerZec: 51234);
    expect(c.lastError, isNull);
  });

  test('forgetting a bill forgets its key too', () async {
    final keys = SplitsKeys(store: InMemorySecretStore(), random: Random(1));
    final c = controllerFor(FakeWallet(), keys: keys);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    expect(c.bills, hasLength(1));
    await c.forget(id);
    expect(c.bills, isEmpty);
    expect(await keys.readBillKey(id), isNull);
  });

  test(
    'two people with one name are told apart, and the organiser is named',
    () async {
      final c = controllerFor(FakeWallet());
      await c.load();
      final id = (await c.createBill(
        name: 'Dinner',
        currency: 'EUR',
        displayName: 'Ana',
      ))!;

      // A second Ana joins from another device.
      final other = FakeWallet(id: 'ana2', payTo: 'u1other');
      other.tick();
      other.tick();
      await c.accept(id, [
        splitz.joinBill(
          host: WalletBillHost(other),
          name: 'Ana',
          payTo: 'u1other',
        ),
      ]);

      final bill = c.bills.single;
      expect(
        bill.bill.displayNameOf(c.me, creatorId: bill.creatorId),
        'Ana (organiser)',
      );
      expect(
        bill.bill.displayNameOf('ana2', creatorId: bill.creatorId),
        startsWith('Ana ('),
      );
      expect(
        bill.bill.displayNameOf('ana2', creatorId: bill.creatorId),
        isNot('Ana (organiser)'),
      );
    },
  );

  test('a name is what the person typed, never the account id, and saving '
      'a payout keeps it', () async {
    final wallet = FakeWallet(id: 'account-uuid-7');
    final c = controllerFor(wallet);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    // Nothing typed: no name, rather than the wallet's own handle.
    expect(c.bills.single.bill.participant(c.me)!.name, isEmpty);

    wallet.tick();
    await c.setPayouts(
      billId: id,
      payouts: const [splitz.Payout(type: 'zec', address: 'u1ana')],
      displayName: 'Ana',
    );
    expect(c.bills.single.bill.participant(c.me)!.name, 'Ana');
    wallet.tick();
    await c.setPayouts(
      billId: id,
      payouts: const [splitz.Payout(type: 'zec', address: 'u1ana2')],
    );
    expect(c.lastError, isNull);
    expect(c.bills.single.bill.participant(c.me)!.name, 'Ana');
  });

  test('an entry the fold set aside is never taken for the expense it '
      'shares an id with', () async {
    final wallet = FakeWallet();
    final c = controllerFor(wallet);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;
    await c.accept(id, [
      splitz.joinBill(host: otherHost('ben'), name: 'Ben', payTo: 'u1ben'),
    ]);
    wallet.tick();
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 9000,
      among: [c.me, 'ben'],
    );
    final expenseId = c.bills.single.bill.expenses.single.id;
    final mine = c.bills.single.expenseEntries[expenseId];

    // Ben writes an earlier entry under the same expense id, paid by
    // somebody who is not on the bill, so the fold sets it aside.
    await c.accept(id, [
      splitz.addExpense(
        host: otherHost('ben'),
        expenseId: expenseId,
        paidBy: 'nobody',
        amount: -9000,
        split: const <String, dynamic>{
          'type': 'equal',
          'among': ['ben'],
        },
      ),
    ]);
    final view = c.bills.single;
    expect(view.setAside, hasLength(1));
    expect(view.expenseAuthors[expenseId], c.me);
    expect(view.expenseEntries[expenseId], mine);
  });

  test('a refresh that finishes after a later one does not publish the '
      'older bill', () async {
    final storage = _HeldReads();
    final wallet = FakeWallet();
    final c = SplitsController(
      wallet: wallet,
      store: BillStore(storage),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(1)),
    );
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'EUR'))!;

    // The first change's refresh reads the bill and then stalls; the second
    // change lands and refreshes in full meanwhile.
    storage.holdRead(after: 1);
    final first = c.accept(id, [
      splitz.joinBill(host: otherHost('ben'), name: 'Ben', payTo: 'u1ben'),
    ]);
    await storage.held;
    await c.accept(id, [
      splitz.joinBill(host: otherHost('cai'), name: 'Cai', payTo: 'u1cai'),
    ]);
    expect(c.bills.single.bill.participants, hasLength(3));
    storage.release();
    await first;
    expect(
      c.bills.single.bill.participants,
      hasLength(3),
      reason: 'the stalled refresh read the bill before Cai joined',
    );
  });

  test('an amount renders from integers, never from a double', () {
    expect(formatAmount(9000, 'EUR'), '90.00 EUR');
    expect(formatAmount(5, 'EUR'), '0.05 EUR');
    expect(formatAmount(-4500, 'EUR'), '-45.00 EUR');
    expect(formatAmount(123, 'JPY', exponent: 0), '123 JPY');
    // A figure a double cannot hold exactly.
    expect(formatAmount(9007199254740993, 'EUR'), '90071992547409.93 EUR');
  });
}

/// Storage whose next bill read after [holdRead]'s count returns its value
/// only once [release] is called: a refresh that read the bill and then
/// stalled.
class _HeldReads extends InMemoryBillStorage {
  int? _skip;
  Completer<void>? _gate;
  final Completer<void> _reached = Completer<void>();

  Future<void> get held => _reached.future;

  void holdRead({required int after}) => _skip = after;

  void release() => _gate?.complete();

  @override
  Future<String?> read(String key) async {
    final value = await super.read(key);
    if (_skip != null && key.startsWith('splitz_bill_')) {
      if (_skip == 0) {
        _skip = null;
        _gate = Completer<void>();
        _reached.complete();
        await _gate!.future;
      } else {
        _skip = _skip! - 1;
      }
    }
    return value;
  }
}
