// The organiser's own price is never replaced by a feed answer that was
// asked for before it and arrived after it.

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// A feed that answers only when [answer] is called.
class _HeldFeed implements ZecPrices {
  final _gate = Completer<int?>();
  int asked = 0;

  void answer(int? price) => _gate.complete(price);

  @override
  Future<int?> minorUnitsPerZec(String currency) {
    asked++;
    return _gate.future;
  }
}

SplitsController _ctl(ZecPrices prices, [FakeWallet? wallet]) =>
    SplitsController(
      wallet: wallet ?? FakeWallet(),
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(9)),
      relay: const UnconfiguredSplitsRelay(),
      prices: prices,
    );

void main() {
  test(
    'a price the organiser set while the feed was answering stands',
    () async {
      final feed = _HeldFeed();
      final wallet = FakeWallet();
      final c = _ctl(feed, wallet);
      await c.load();
      final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
      await pumpEventQueue();
      expect(feed.asked, 1, reason: 'opening the bill asked the feed');

      wallet.tick();
      await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
      // The feed answers after the organiser's price, as on a device, where its
      // entry is then written later and orders after it (§10.2).
      wallet.tick();
      feed.answer(137500);
      await pumpEventQueue();
      await c.load();

      expect(c.bills.single.bill.rate?.minorUnitsPerZec, 100000);
      expect(c.bills.single.bill.rate?.source, isNot('feed'));
    },
  );

  test('with no price of its own, the feed answer is the price', () async {
    final feed = _HeldFeed();
    final c = _ctl(feed);
    await c.load();
    await c.createBill(name: 'Trip', currency: 'USD');
    await pumpEventQueue();
    feed.answer(137500);
    await pumpEventQueue();
    await c.load();
    expect(c.bills.single.bill.rate?.minorUnitsPerZec, 137500);
    expect(c.bills.single.bill.rate?.source, 'feed');
  });

  test('a feed with no answer sets nothing', () async {
    final feed = _HeldFeed();
    final c = _ctl(feed);
    await c.load();
    await c.createBill(name: 'Trip', currency: 'USD');
    await pumpEventQueue();
    feed.answer(null);
    await pumpEventQueue();
    await c.load();
    expect(c.bills.single.bill.rate, isNull);
  });
}
