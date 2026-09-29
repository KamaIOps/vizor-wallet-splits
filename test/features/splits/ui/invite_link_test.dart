/// An invite that arrives as an opened link rather than a scan.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/splitz_core.dart' as splitz;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(
  FakeWallet wallet, {
  SplitsRelay relay = const UnconfiguredSplitsRelay(),
  int seed = 3,
  SplitsKeys? keys,
}) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: keys ?? SplitsKeys(store: InMemorySecretStore(), random: Random(seed)),
  relay: relay,
);

/// Ana's bill on [relay], and the invite she would send.
Future<(String, String)> anasBill(SplitsRelay relay) async {
  final ana = controllerFor(FakeWallet(), relay: relay, seed: 1);
  await ana.load();
  final id = (await ana.createBill(name: 'Dinner', currency: 'EUR'))!;
  final invite = await ana.inviteFor(id);
  if (relay is! UnconfiguredSplitsRelay) await ana.syncBill(id);
  return (id, invite);
}

Widget openedWith(SplitsController c, String code) => MaterialApp(
  home: SplitsNavigator(controller: c, initialCode: code),
);

void main() {
  testWidgets('a link opens the bill it names, fetched from the relay', (
    t,
  ) async {
    final relay = InMemorySplitsRelay();
    final (id, invite) = await anasBill(relay);
    final ben = controllerFor(
      FakeWallet(id: 'ben', payTo: 'u1ben'),
      relay: relay,
      seed: 2,
    );
    await ben.load();

    await t.pumpWidget(openedWith(ben, invite));
    await t.pumpAndSettle();

    // Opening the link shows the invite and does nothing else.
    expect(find.textContaining('An invite to “Dinner”'), findsOneWidget);
    expect(find.byType(BillScreen), findsNothing);
    expect(ben.bills, isEmpty);

    await t.tap(find.byKey(const Key('splits_scan_read')));
    await t.pumpAndSettle();

    expect(find.byType(BillScreen), findsOneWidget);
    expect(ben.bills.map((b) => b.id), contains(id));
  });

  testWidgets('a relay that lacks the bill says so, and holds the key', (
    t,
  ) async {
    final (id, invite) = await anasBill(const UnconfiguredSplitsRelay());
    final keys = SplitsKeys(store: InMemorySecretStore(), random: Random(2));
    final ben = controllerFor(
      FakeWallet(id: 'ben', payTo: 'u1ben'),
      relay: InMemorySplitsRelay(),
      keys: keys,
    );
    await ben.load();

    await t.pumpWidget(openedWith(ben, invite));
    await t.pumpAndSettle();
    expect(await keys.readBillKey(id), isNull, reason: 'not joined on open');
    await t.tap(find.byKey(const Key('splits_scan_read')));
    await t.pumpAndSettle();

    expect(find.byType(BillScreen), findsNothing);
    expect(find.textContaining('hasn’t synced yet'), findsOneWidget);
    expect(await keys.readBillKey(id), isNotNull);
  });

  testWidgets('with no relay, the key is kept and the bill asked for', (
    t,
  ) async {
    final (id, invite) = await anasBill(const UnconfiguredSplitsRelay());
    final keys = SplitsKeys(store: InMemorySecretStore(), random: Random(2));
    final ben = controllerFor(
      FakeWallet(id: 'ben', payTo: 'u1ben'),
      keys: keys,
    );
    await ben.load();

    await t.pumpWidget(openedWith(ben, invite));
    await t.pumpAndSettle();
    expect(await keys.readBillKey(id), isNull, reason: 'not joined on open');
    await t.tap(find.byKey(const Key('splits_scan_read')));
    await t.pumpAndSettle();

    expect(find.byType(BillScreen), findsNothing);
    expect(find.textContaining('Now scan the bill’s code'), findsOneWidget);
    expect(await keys.readBillKey(id), isNotNull);
  });

  testWidgets('a link that is not an invite is refused by its code', (t) async {
    final ben = controllerFor(FakeWallet(id: 'ben', payTo: 'u1ben'), seed: 2);
    await ben.load();

    await t.pumpWidget(openedWith(ben, 'splitz://join?v=1&b=a+b&k=AAAA'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_scan_read')));
    await t.pumpAndSettle();

    expect(find.byType(BillScreen), findsNothing);
    expect(find.textContaining('invite_bad_bill_id'), findsOneWidget);
  });

  testWidgets('an invite its sender marked expired says so', (t) async {
    final ben = controllerFor(FakeWallet(id: 'ben', payTo: 'u1ben'), seed: 2);
    await ben.load();
    final (_, invite) = await anasBill(const UnconfiguredSplitsRelay());
    // FakeWallet's clock reads 2026-10-28; one second after the epoch is long
    // gone, and nineteen digits must not overflow the comparison.
    for (final (x, expired) in [('1', true), ('9223372036854775807', false)]) {
      await t.pumpWidget(openedWith(ben, '$invite&x=$x'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('marked it as expired'),
        expired ? findsOneWidget : findsNothing,
        reason: 'x=$x',
      );
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('an invite carrying another key for a held bill is not taken '
      'without asking, and the held one is kept by default', (t) async {
    // Ana's bill, invited twice under two keys. Taking the second would
    // leave this device writing records its peers cannot open.
    final (id, invite) = await anasBill(const UnconfiguredSplitsRelay());
    final keys = SplitsKeys(store: InMemorySecretStore(), random: Random(2));
    final ben = controllerFor(
      FakeWallet(id: 'ben', payTo: 'u1ben'),
      keys: keys,
    );
    await ben.load();
    await ben.acceptKey(id, splitz.parseInvite(invite).key);
    final held = await keys.readBillKey(id);

    final other = splitz.renderInvite(
      splitz.Invite(billId: id, key: 'A' * 43, name: 'Dinner'),
    );
    await t.pumpWidget(openedWith(ben, other));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_scan_read')));
    await t.pumpAndSettle();

    expect(find.text('A different key for this bill'), findsOneWidget);
    expect(await keys.readBillKey(id), held);
    await t.tap(find.text('Keep the one I have'));
    await t.pumpAndSettle();
    expect(await keys.readBillKey(id), held);
  });

  testWidgets('a person who knows the held key came from a forged link can '
      'take the genuine one', (t) async {
    // The first link for a bill is not necessarily the genuine one, and one
    // held key must not lock this device out of the bill for good.
    final (id, invite) = await anasBill(const UnconfiguredSplitsRelay());
    final keys = SplitsKeys(store: InMemorySecretStore(), random: Random(2));
    final ben = controllerFor(
      FakeWallet(id: 'ben', payTo: 'u1ben'),
      keys: keys,
    );
    await ben.load();
    await ben.acceptKey(id, 'A' * 43);

    await t.pumpWidget(openedWith(ben, invite));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_scan_read')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_scan_replace_key')));
    await t.pumpAndSettle();
    expect(await keys.readBillKey(id), splitz.parseInvite(invite).key);
  });
}
