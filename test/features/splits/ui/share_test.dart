/// Sharing a code through the wallet's share sheet.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

void main() {
  testWidgets('each code shares exactly the string it shows', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final shared = <String>[];
    final origins = <Rect?>[];

    await t.pumpWidget(
      SplitsScope(
        controller: c,
        share: (context, text, {Rect? origin}) async {
          shared.add(text);
          origins.add(origin);
        },
        child: MaterialApp(home: ShareBillScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('splits_share_Bill code')));
    await t.scrollUntilVisible(
      find.byKey(const Key('splits_share_Invite')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_share_Invite')));
    await t.pump();

    expect(shared, [await c.shareableBill(id), await c.inviteFor(id)]);
    expect(shared.last, startsWith('splitz://join?'));
    // An iPad anchors the sheet's popover here; a missing rect crashes it.
    expect(origins, everyElement(isNotNull));
    expect(origins.every((r) => !r!.isEmpty), isTrue);
  });

  testWidgets('a wallet with no share sheet gets no share button', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(home: ShareBillScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();

    expect(find.byTooltip('Copy'), findsWidgets);
    expect(find.byTooltip('Share'), findsNothing);
  });

  testWidgets('the navigator a wallet mounts passes its share sheet down', (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    Future<void> share(BuildContext _, String _, {Rect? origin}) async {}

    await t.pumpWidget(
      MaterialApp(
        home: SplitsNavigator(controller: c, share: share),
      ),
    );
    await t.pumpAndSettle();

    final screen = t.element(find.byType(BillsScreen));
    expect(SplitsScope.sharerOf(screen), same(share));
  });
}
