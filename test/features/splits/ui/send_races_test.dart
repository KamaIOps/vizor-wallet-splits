/// Sends that overlap a second send, a forget, a kill or a second store.
///
/// Every interleaving is driven by an injected Completer, never a sleep.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// A sender that answers only when told to.
class GatedSender implements WalletSender {
  GatedSender(this.payToAddress);
  @override
  final String? payToAddress;
  final List<String> sent = [];
  final List<Completer<WalletSendOutcome>> gates = [];

  @override
  Future<WalletSendOutcome> send(String uri) {
    sent.add(uri);
    final c = Completer<WalletSendOutcome>();
    gates.add(c);
    return c.future;
  }
}

class GatedWallet implements SplitsWallet {
  GatedWallet({String id = 'ana'})
    : account = WalletAccount(id: id, identitySecret: 'secret-$id'.codeUnits),
      sender = GatedSender('u1ana000000000000000000');
  @override
  final WalletAccount account;
  @override
  final GatedSender sender;
  @override
  final SecretStore secrets = InMemorySecretStore();
  DateTime _at = DateTime.utc(2026, 10, 28, 19, 30);
  void tick() => _at = _at.add(const Duration(minutes: 1));
  int _counter = 0;
  @override
  DateTime now() => _at;
  @override
  Uint8List randomBytes(int n) {
    _counter++;
    return Uint8List.fromList(List<int>.generate(n, (i) => _counter + i));
  }
}

/// Storage whose next read of [gateKey] waits on [gate].
class GatedStorage implements BillStorage {
  final InMemoryBillStorage inner = InMemoryBillStorage();
  String? gateKey;
  Completer<void>? gate;
  Completer<void>? reached;
  String? failDeletePrefix;

  @override
  Future<String?> read(String key) async {
    final v = await inner.read(key);
    if (key == gateKey && gate != null) {
      final g = gate!;
      gate = null;
      reached?.complete();
      await g.future;
    }
    return v;
  }

  @override
  Future<void> write(String key, String value) => inner.write(key, value);

  @override
  Future<void> delete(String key) async {
    if (failDeletePrefix != null && key.startsWith(failDeletePrefix!)) {
      failDeletePrefix = null;
      throw StateError('process killed here');
    }
    return inner.delete(key);
  }

  @override
  Future<List<String>> keys(String prefix) => inner.keys(prefix);
  @override
  Future<int> sweepUnfinishedWrites() async => 0;
}

SplitsController controllerOver(
  SplitsWallet w,
  BillStorage s, {
  SecretStore? secrets,
  int seed = 3,
}) => SplitsController(
  wallet: w,
  store: BillStore(s),
  keys: SplitsKeys(
    store: secrets ?? InMemorySecretStore(),
    random: Random(seed),
  ),
  relay: const UnconfiguredSplitsRelay(),
);

Future<String> owingBen(SplitsController c) async {
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'ben', payTo: 'u1benpayable0000000001'),
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
  return id;
}

const _txid =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  test('two settles started in one turn send once', () async {
    final w = GatedWallet();
    final c = controllerOver(w, InMemoryBillStorage());
    final id = await owingBen(c);
    final owed = (await c.obligation(id))!;

    final a = c.settle(id, owed);
    final b = c.settle(id, owed);
    await pumpEventQueue();
    for (final g in w.sender.gates) {
      g.complete(
        const WalletSendOutcome(phase: WalletSendPhase.succeeded, txid: _txid),
      );
    }
    await Future.wait([a, b]);
    expect(w.sender.sent, hasLength(1));
  });

  test(
    'a bill with a send out cannot be removed, and is not sent twice',
    () async {
      final w = GatedWallet();
      final c = controllerOver(w, InMemoryBillStorage());
      final id = await owingBen(c);
      final a = c.settle(id, (await c.obligation(id))!);
      await pumpEventQueue();

      await c.forget(id);
      expect(c.lastError, contains('earlier send'));
      expect(c.bills.map((b) => b.id), contains(id));

      w.sender.gates.single.complete(
        const WalletSendOutcome(phase: WalletSendPhase.pendingBroadcast),
      );
      await a;
      await c.forget(id);
      expect(c.lastError, contains('earlier send'));
      await c.settle(id, (await c.obligation(id))!);
      expect(w.sender.sent, hasLength(1));
    },
  );

  test('a send that lands after its bill is gone writes nothing back, and '
      'keeps the transaction', () async {
    final w = GatedWallet();
    final secrets = InMemorySecretStore();
    final storage = InMemoryBillStorage();
    final c = controllerOver(w, storage, secrets: secrets);
    final id = await owingBen(c);
    final a = c.settle(id, (await c.obligation(id))!);
    await pumpEventQueue();

    // Removed underneath the send — by another screen's controller over the
    // same storage.
    await SplitsKeys(store: secrets).forgetBill(id);
    await BillStore(storage).forget(id);
    w.sender.gates.single.complete(
      const WalletSendOutcome(phase: WalletSendPhase.succeeded, txid: _txid),
    );
    await a;

    expect(await BillStore(storage).read(id), isEmpty);
    final intent = await c.pendingSend(id);
    expect(intent, isNotNull);
    expect(intent!.txid, _txid);
  });

  test('a forget killed part-way is finished on the next launch', () async {
    final w = GatedWallet();
    final secrets = InMemorySecretStore();
    final storage = GatedStorage();
    final c = controllerOver(w, storage, secrets: secrets);
    final id = await owingBen(c);
    final realKey = await c.billKey(id);

    storage.failDeletePrefix = 'splitz_bill_'; // killed after the key went
    await c.forget(id);
    expect(c.lastError, contains('process killed here'));

    final next = controllerOver(w, storage, secrets: secrets, seed: 99);
    await next.load();
    expect(next.bills.map((b) => b.id), isNot(contains(id)));
    expect(await BillStore(storage).read(id), isEmpty);
    // The real invite is taken, not turned away as a second key.
    await next.acceptKey(id, realKey);
    expect(next.lastError, isNull);
  });

  test('a success with no transaction id keeps the send unresolved', () async {
    final w = GatedWallet();
    final c = controllerOver(w, InMemoryBillStorage());
    final id = await owingBen(c);
    final a = c.settle(id, (await c.obligation(id))!);
    await pumpEventQueue();
    w.sender.gates.single.complete(
      const WalletSendOutcome(phase: WalletSendPhase.succeeded),
    );
    await a;
    expect(await c.pendingSend(id), isNotNull);
    expect(c.bills.single.bill.payments, isEmpty);
  });

  test(
    'resolving a send whose records were written records nothing twice',
    () async {
      final w = GatedWallet();
      final storage = GatedStorage();
      final c = controllerOver(w, storage);
      final id = await owingBen(c);
      final a = c.settle(id, (await c.obligation(id))!);
      await pumpEventQueue();
      storage.failDeletePrefix =
          'pendingsend/'; // killed before the note clears
      w.sender.gates.single.complete(
        const WalletSendOutcome(phase: WalletSendPhase.succeeded, txid: _txid),
      );
      await a;
      expect(await c.pendingSend(id), isNotNull);

      w.tick();
      await c.resolveSend(id, landed: true, txid: _txid);
      expect(c.lastError, isNull);
      final log = await BillStore(storage).read(id);
      expect(log.where((e) => e['kind'] == 'recordPayment'), hasLength(1));
      expect(c.bills.single.setAside, isEmpty);
      expect(await c.pendingSend(id), isNull);
    },
  );
}
