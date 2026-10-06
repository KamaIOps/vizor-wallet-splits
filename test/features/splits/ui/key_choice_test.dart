// A bill's key, chosen or refused: §9.4 against what this device holds, and a
// sync that fails under one key while a person chooses another.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/splitz_core.dart' as splitz;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// A relay whose fetch can be held open, so a sync is in flight on demand.
class _HeldRelay implements SplitsRelay {
  final inner = InMemorySplitsRelay();
  Completer<void>? hold;
  Completer<void>? reached;

  @override
  Future<void> push(String channel, List<String> blobs) =>
      inner.push(channel, blobs);

  @override
  Future<List<String>> fetch(String channel) async {
    reached?.complete();
    reached = null;
    await hold?.future;
    return inner.fetch(channel);
  }
}

String _b64(List<int> raw) => base64UrlEncode(raw).replaceAll('=', '');

void main() {
  late _HeldRelay relay;
  late String id;
  late String genuine;
  late String forged;
  late List<Map<String, dynamic>> log;

  setUp(() async {
    relay = _HeldRelay();
    final anaStore = BillStore(InMemoryBillStorage());
    final ana = SplitsController(
      wallet: FakeWallet(id: 'ana', payTo: 'u1ana'),
      store: anaStore,
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      relay: relay,
    );
    await ana.load();
    id = (await ana.createBill(name: 'Dinner', currency: 'USD'))!;
    await ana.syncBill(id);
    genuine = await ana.billKey(id);
    forged = _b64(List<int>.generate(32, (i) => 200 - i));
    log = await anaStore.read(id);
  });

  Future<(SplitsController, SplitsKeys, BillStore)> device({
    String name = 'vic',
  }) async {
    final secrets = InMemorySecretStore();
    final store = BillStore(InMemoryBillStorage());
    final c = SplitsController(
      wallet: FakeWallet(id: name, payTo: 'u1$name'),
      store: store,
      keys: SplitsKeys(store: secrets, random: Random(5)),
      relay: relay,
    );
    await c.load();
    return (c, SplitsKeys(store: secrets), store);
  }

  /// The genuine log sealed under [forged] onto the bill's own channel.
  Future<void> forgeChannel() async {
    final sealing = SplitsSealing();
    await relay.inner.push(SplitsChannel.forBill(id), [
      for (final e in log) await sealing.seal(e, forged),
    ]);
  }

  group('a sync that fails under one key', () {
    test('forgets the key it used when nothing replaced it', () async {
      await forgeChannel();
      final (c, keys, _) = await device();
      await c.acceptKey(id, forged);
      await c.syncBill(id);
      expect(c.syncStateOf(id).phase, SplitsSyncPhase.failed);
      expect(await keys.readBillKey(id), isNull);
    });

    test('keeps a key chosen while it was in flight', () async {
      await forgeChannel();
      final (c, keys, _) = await device();
      await c.acceptKey(id, forged);

      relay.hold = Completer<void>();
      relay.reached = Completer<void>();
      final reached = relay.reached!.future;
      final syncing = c.syncBill(id);
      await reached;
      await c.replaceKey(id, genuine);
      expect(c.lastError, isNull);
      relay.hold!.complete();
      await syncing;

      expect(c.syncStateOf(id).phase, SplitsSyncPhase.failed);
      expect(
        await keys.readBillKey(id),
        genuine,
        reason: 'the key chosen during the sync is not the one it failed on',
      );
      await c.syncBill(id);
      expect(c.syncStateOf(id).phase, SplitsSyncPhase.synced);
    });
  });

  group('a key the held create refuses', () {
    test('replaceKey refuses it and keeps the held key', () async {
      final (c, keys, store) = await device();
      await c.acceptKey(id, genuine);
      await c.syncBill(id);
      expect((await store.read(id)).length, log.length);

      await c.replaceKey(id, forged);
      expect(c.lastError, contains('doesn\'t fit this bill'));
      expect(await keys.readBillKey(id), genuine);
    });

    test('acceptKey refuses it on a bill held without a key', () async {
      final (c, keys, store) = await device();
      await store.merge(id, log);
      await c.acceptKey(id, forged);
      expect(c.lastError, contains('doesn\'t fit this bill'));
      expect(await keys.readBillKey(id), isNull);

      await c.acceptKey(id, genuine);
      expect(c.lastError, isNull);
      expect(await keys.readBillKey(id), genuine);
    });

    test('replaceKey still takes a key when nothing held decides', () async {
      final (c, keys, store) = await device();
      await c.acceptKey(id, forged);
      expect(await store.read(id), isEmpty);
      await c.replaceKey(id, genuine);
      expect(c.lastError, isNull);
      expect(await keys.readBillKey(id), genuine);
    });

    testWidgets('a scanned code with no create is refused, not asked about', (
      t,
    ) async {
      final (c, keys, store) = await device(name: 'ben');
      await t.runAsync(() async {
        await c.acceptKey(id, genuine);
        await c.syncBill(id);
      });
      final code = splitz.encodePayload(splitz.billPrefix, {
        'v': 1,
        'invite': {'v': 1, 'b': id, 'k': forged},
        'log': <Object>[],
      });
      await t.pumpWidget(
        MaterialApp(
          home: SplitsNavigator(controller: c, initialCode: code),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('splits_scan_name')), 'Ben');
      await t.pump();
      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();

      expect(find.text('A different key for this bill'), findsNothing);
      expect(find.textContaining('doesn\'t fit this bill'), findsOneWidget);
      expect(await t.runAsync(() => keys.readBillKey(id)), genuine);
      expect((await t.runAsync(() => store.read(id)))!.length, log.length);
      await t.pumpWidget(const SizedBox());
      c.stopPolling(null);
    });

    testWidgets('a code the held bill cannot judge still asks', (t) async {
      final (c, keys, _) = await device(name: 'ben');
      await t.runAsync(() => c.acceptKey(id, forged));
      final code = splitz.encodePayload(splitz.billPrefix, {
        'v': 1,
        'invite': {'v': 1, 'b': id, 'k': genuine},
        'log': <Object>[],
      });
      await t.pumpWidget(
        MaterialApp(
          home: SplitsNavigator(controller: c, initialCode: code),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('splits_scan_name')), 'Ben');
      await t.pump();
      await t.tap(find.byKey(const Key('splits_scan_read')));
      await t.pumpAndSettle();

      expect(find.text('A different key for this bill'), findsOneWidget);
      await t.tap(find.byKey(const Key('splits_scan_replace_key')));
      await t.pumpAndSettle();
      expect(await t.runAsync(() => keys.readBillKey(id)), genuine);
      await t.pumpWidget(const SizedBox());
      c.stopPolling(null);
    });
  });
}
