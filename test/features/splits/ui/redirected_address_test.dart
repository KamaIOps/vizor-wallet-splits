// A payer is warned when an address somebody had is replaced, not when
// somebody added by name is given their first one.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

void main() {
  test('a first address is no redirect; replacing it is', () async {
    final wallet = FakeWallet();
    final c = SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: const UnconfiguredSplitsRelay(),
    );
    await c.load();
    final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
    await c.addPerson(billId: id, id: 'ben', name: 'Ben');
    wallet.tick();
    await c.setAddressFor(billId: id, id: 'ben', address: 'u1benfirst');
    expect(c.lastError, isNull);

    var view = c.bills.single;
    expect(view.replacedAddresses.map((r) => (r.from, r.to)), [
      (null, 'u1benfirst'),
    ]);
    expect(view.redirectedAddresses, isEmpty);

    wallet.tick();
    await c.setAddressFor(billId: id, id: 'ben', address: 'u1bensecond');
    expect(c.lastError, isNull);
    view = c.bills.single;
    expect(view.redirectedAddresses.map((r) => (r.id, r.from, r.to)), [
      ('ben', 'u1benfirst', 'u1bensecond'),
    ]);
  });
}
