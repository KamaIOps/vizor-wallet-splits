// A sync whose push is refused still shows what its pull brought.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// [shared] for fetches; pushes refused, as a full channel refuses them.
class _NoPush implements SplitsRelay {
  _NoPush(this.shared, {this.fetches = true});

  final SplitsRelay shared;
  final bool fetches;

  @override
  Future<void> push(String channel, List<String> blobs) async =>
      throw const SplitsRelayException('the channel is full');

  @override
  Future<List<String>> fetch(String channel) async => fetches
      ? shared.fetch(channel)
      : throw const SplitsRelayException('unreachable', isTransient: true);
}

SplitsController _device(
  String id,
  SplitsRelay relay, {
  required BillStore store,
  required SplitsKeys keys,
}) => SplitsController(
  wallet: FakeWallet(id: id, payTo: 'u1$id'.padRight(24, '0')),
  store: store,
  keys: keys,
  relay: relay,
);

/// Ana opens a bill and syncs it; Ben joins through the shared relay. Ana's
/// phone then syncs through [anaRelay].
Future<SplitsController> _benJoinsThenAnaSyncs(
  SplitsRelay Function(SplitsRelay shared) anaRelay,
) async {
  final shared = InMemorySplitsRelay();
  final store = BillStore(InMemoryBillStorage());
  final keys = SplitsKeys(store: InMemorySecretStore(), random: Random(1));
  final setup = _device('ana', shared, store: store, keys: keys);
  await setup.load();
  final id = (await setup.createBill(name: 'Dinner', currency: 'USD'))!;
  final key = await setup.billKey(id);
  await setup.syncBill(id);

  final ben = _device(
    'ben',
    shared,
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(2)),
  );
  await ben.load();
  await ben.acceptKey(id, key);
  await ben.syncBill(id);
  await ben.join(id);
  await ben.syncBill(id);

  final ana = _device('ana', anaRelay(shared), store: store, keys: keys);
  await ana.load();
  // Something of Ana's own the channel does not hold yet, so the sync pushes.
  await ana.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  expect(ana.bills.single.bill.participants, hasLength(1));
  await ana.syncBill(id);
  expect(ana.syncStateOf(id).phase, SplitsSyncPhase.failed);
  return ana;
}

void main() {
  test('a refused push still shows what the pull brought', () async {
    final ana = await _benJoinsThenAnaSyncs((shared) => _NoPush(shared));
    expect(ana.bills.single.bill.participants, hasLength(2));
  });

  test('a sync that pulled nothing shows nothing new', () async {
    final ana = await _benJoinsThenAnaSyncs(
      (shared) => _NoPush(shared, fetches: false),
    );
    expect(ana.bills.single.bill.participants, hasLength(1));
  });
}
