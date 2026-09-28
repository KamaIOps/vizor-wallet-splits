/// Removing a bill from this device.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet, SplitsKeys keys) =>
    SplitsController(
      wallet: wallet,
      store: BillStore(InMemoryBillStorage()),
      keys: keys,
      relay: const UnconfiguredSplitsRelay(),
    );

void main() {
  testWidgets('a bill is removed only after saying what that costs', (t) async {
    final keys = SplitsKeys(store: InMemorySecretStore(), random: Random(3));
    final c = controllerFor(FakeWallet(), keys);
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

    await t.pumpWidget(MaterialApp(home: SplitsNavigator(controller: c)));
    await t.pumpAndSettle();
    await t.tap(find.text('Dinner'));
    await t.pumpAndSettle();
    expect(find.byType(BillScreen), findsOneWidget);

    Future<void> openRemove() async {
      await t.tap(find.byKey(const Key('splits_bill_menu')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('splits_bill_forget')));
      await t.pumpAndSettle();
    }

    // Backing out keeps it.
    await openRemove();
    expect(find.textContaining('Everyone else keeps it'), findsOneWidget);
    await t.tap(find.text('Keep it'));
    await t.pumpAndSettle();
    expect(c.bills.map((b) => b.id), contains(id));
    expect(await keys.readBillKey(id), isNotNull);

    await openRemove();
    await t.tap(find.byKey(const Key('splits_bill_forget_confirm')));
    await t.pumpAndSettle();

    expect(c.bills.map((b) => b.id), isNot(contains(id)));
    expect(await keys.readBillKey(id), isNull);
    // Back on the list, not on a screen for a bill that is gone.
    expect(find.byType(BillScreen), findsNothing);
    expect(find.byType(BillsScreen), findsOneWidget);
  });

  test('a sync in flight cannot bring a forgotten bill back', () async {
    // The sync's answer lands while the forget is part-way through. With the
    // key forgotten first, the sync's merge — which runs only while the key
    // is held — either lands before the store forgets the bill or not at
    // all. Forgetting the store first let it land in between and leave a
    // bill with no key to read or share it.
    final relay = _HeldRelay();
    final secrets = _HeldSecrets();
    final storage = InMemoryBillStorage();
    final c = SplitsController(
      wallet: FakeWallet(),
      store: BillStore(storage),
      keys: SplitsKeys(store: secrets, random: Random(3)),
      relay: relay,
    );
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    await c.syncBill(id);
    expect(c.lastError, isNull);

    final fetched = relay.hold = Completer<void>();
    final syncing = c.syncBill(id);
    final deleted = secrets.holdDelete = Completer<void>();
    final forgetting = c.forget(id);
    await pumpEventQueue();

    fetched.complete();
    await pumpEventQueue();
    deleted.complete();
    await forgetting;
    await syncing;

    expect(await BillStore(storage).billIds(), isNot(contains(id)));
    expect(c.bills.map((b) => b.id), isNot(contains(id)));
  });
}

class _HeldRelay implements SplitsRelay {
  final _inner = InMemorySplitsRelay();
  Completer<void>? hold;

  @override
  Future<void> push(String channel, List<String> blobs) =>
      _inner.push(channel, blobs);

  @override
  Future<List<String>> fetch(String channel) async {
    await hold?.future;
    return _inner.fetch(channel);
  }
}

class _HeldSecrets implements SecretStore {
  final _inner = InMemorySecretStore();
  Completer<void>? holdDelete;

  @override
  Future<String?> read(String key) => _inner.read(key);

  @override
  Future<void> write(String key, String value) => _inner.write(key, value);

  @override
  Future<void> delete(String key) async {
    await holdDelete?.future;
    await _inner.delete(key);
  }
}
