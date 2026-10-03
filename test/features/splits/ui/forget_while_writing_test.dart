// Nothing is written into a bill forgotten while the write was on its way:
// it would sit in storage with no key, unlisted.

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

class GatedSwaps implements SwapProvider {
  SwapState reports = SwapState.failed;

  @override
  Future<List<TradableAsset>> tradableAssets() async => const [
    nativeZec,
    TradableAsset(
      assetId: 'base-usdc',
      symbol: 'USDC',
      chain: 'base',
      decimals: 6,
    ),
  ];

  @override
  Future<SwapQuote> quote({
    required TradableAsset asset,
    required int amountInZatoshi,
    required String recipient,
    required String refundTo,
  }) async => SwapQuote(
    depositAddress: 'u1provider',
    amountInZatoshi: amountInZatoshi,
    amountOut: '9500000',
    minAmountOut: '9405000',
    asset: asset,
    deadline: '2099-01-01T00:00:00.000Z',
    reference: 'near-intent-7f3a',
    recipient: recipient,
  );

  @override
  Future<SwapStatus> statusOf(SwapQuote quote) async =>
      SwapStatus(state: reports);
}

/// Storage whose next read of [armedKey] takes its value at once and hands it
/// back only when [gate] completes: a slow disk read.
class GatedStorage implements BillStorage {
  final inner = InMemoryBillStorage();
  String? armedKey;
  Completer<void>? gate;
  final reached = Completer<void>();

  @override
  Future<String?> read(String key) async {
    final v = await inner.read(key);
    if (key == armedKey && gate != null) {
      armedKey = null;
      reached.complete();
      await gate!.future;
    }
    return v;
  }

  @override
  Future<void> write(String key, String value) => inner.write(key, value);
  @override
  Future<void> delete(String key) => inner.delete(key);
  @override
  Future<List<String>> keys(String prefix) => inner.keys(prefix);
  @override
  Future<int> sweepUnfinishedWrites() => inner.sweepUnfinishedWrites();
}

/// A keychain that, once [locked], refuses every read as a locked session
/// does.
class LockingSecretStore extends InMemorySecretStore {
  bool locked = false;

  @override
  Future<String?> read(String key) {
    if (locked) {
      throw StateError('Secret storage requires an unlocked session.');
    }
    return super.read(key);
  }
}

Future<(SplitsController, GatedStorage, SplitsKeys, String)> billWithSwap({
  SwapState reports = SwapState.failed,
  SecretStore? secrets,
}) async {
  final storage = GatedStorage();
  final keys = SplitsKeys(
    store: secrets ?? InMemorySecretStore(),
    random: Random(3),
  );
  final swaps = GatedSwaps()..reports = reports;
  final c = SplitsController(
    wallet: FakeWallet(),
    store: BillStore(storage),
    keys: keys,
    swaps: swaps,
  );
  await c.load();
  final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
  final ben = otherHost('ben');
  await c.accept(id, [
    entries.joinBill(
      host: ben,
      name: 'ben',
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
  final q = await c.quoteSwap(billId: id, to: 'ben', amountMinorUnits: 1000);
  expect(q, isNotNull, reason: 'quote: ${c.lastError}');
  final out = await c.sendSwap(
    billId: id,
    to: 'ben',
    amountMinorUnits: 1000,
    quote: q!,
  );
  expect(c.lastError, isNull);
  expect(out?.phase, WalletSendPhase.succeeded);
  return (c, storage, keys, id);
}

void main() {
  test('forget with nothing in flight leaves no file', () async {
    final (c, s, _, id) = await billWithSwap();
    await c.forget(id);
    expect(c.lastError, isNull);
    expect(await s.inner.read('splitz_bill_$id'), isNull);
  });

  test('a failed swap checked with nothing in between is withdrawn', () async {
    final (c, _, _, id) = await billWithSwap();
    final watch = (await c.swapsInFlight(id)).single;
    await c.checkSwap(watch);
    expect(c.bills.firstWhere((b) => b.id == id).bill.payments, isEmpty);
  });

  test('a forget that lands while Check withdraws leaves no file', () async {
    final (c, s, keys, id) = await billWithSwap();
    final watch = (await c.swapsInFlight(id)).single;
    s.armedKey = 'splitz_bill_$id';
    s.gate = Completer<void>();
    final checking = c.checkSwap(watch);
    await s.reached.future;
    await c.forget(id);
    expect(c.lastError, isNull);
    s.gate!.complete();
    await checking;
    expect(await s.inner.read('splitz_bill_$id'), isNull);
    expect(await keys.readBillKey(id), isNull);
  });

  test('an expense written after its bill lost its key is refused', () async {
    final (c, s, keys, id) = await billWithSwap();
    final before = await s.inner.read('splitz_bill_$id');
    await keys.forgetBill(id);
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 500,
      among: [c.me],
    );
    expect(c.lastError, 'This bill was removed from this phone.');
    expect(await s.inner.read('splitz_bill_$id'), before);
  });

  test('an expense written while the keychain is locked is kept', () async {
    final secrets = LockingSecretStore();
    final (c, _, _, id) = await billWithSwap(secrets: secrets);
    final before = c.bills.single.bill.expenses.length;
    secrets.locked = true;
    await c.addExpense(
      billId: id,
      paidBy: c.me,
      amountMinorUnits: 500,
      among: [c.me],
    );
    expect(c.lastError, isNull);
    expect(c.bills.single.bill.expenses, hasLength(before + 1));
  });
}
