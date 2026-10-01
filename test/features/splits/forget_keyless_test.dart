// Bills adopted from the layout every account shared: a copy whose shared key
// is gone is forgotten, one whose key reads or cannot be asked yet is kept.
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_host/splitz_host.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';

Future<BillStore> _three() async {
  final store = BillStore(InMemoryBillStorage());
  for (final id in ['held', 'gone', 'locked']) {
    await store.merge(id, [
      {'v': 1, 'id': '$id-entry', 'kind': 'createBill'},
    ]);
  }
  return store;
}

void main() {
  test('a bill whose key is gone is forgotten; the others are kept', () async {
    final store = await _three();
    final forgotten = await forgetBillsWithoutKeys(store, (billId) async {
      if (billId == 'locked') throw StateError('the keychain is locked');
      return billId == 'held' ? 'a key' : null;
    });
    expect(forgotten, 1);
    expect((await store.billIds()).toSet(), {'held', 'locked'});
  });

  test('bills that all have keys are all kept', () async {
    final store = await _three();
    expect(await forgetBillsWithoutKeys(store, (_) async => 'a key'), 0);
    expect(await store.billIds(), hasLength(3));
  });

  test('a store with nothing in it forgets nothing', () async {
    final store = BillStore(InMemoryBillStorage());
    expect(await forgetBillsWithoutKeys(store, (_) async => null), 0);
  });
}
