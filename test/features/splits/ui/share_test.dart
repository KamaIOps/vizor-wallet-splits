/// Sharing a code through the wallet's share sheet.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

void main() {
  testWidgets('the bill code shares as shown; the invite as a link that reads '
      'as the same invite', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final shared = <String>[];
    final origins = <Rect?>[];

    Widget screen({required bool whole}) => SplitsScope(
      controller: c,
      share: (context, text, {Rect? origin}) async {
        shared.add(text);
        origins.add(origin);
      },
      child: MaterialApp(
        home: ShareBillScreen(billId: id, wholeBill: whole),
      ),
    );

    await t.pumpWidget(screen(whole: true));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_share_Bill code')));
    await t.pumpWidget(screen(whole: false));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_share_Invite')));
    await t.pump();

    // The invite the screen issues says when its sender stops standing
    // behind it: 30 days on, by this device's clock (§11.1).
    final invite = await c.inviteFor(
      id,
      expiry: c.now().add(const Duration(days: 30)),
    );
    expect(invite, contains('&x='));
    expect(shared.first, await c.shareableBill(id));
    // A chat app shows an https link as one to tap; the invite rides in its
    // fragment, and every reader takes it as the invite the code shows.
    expect(shared.last, 'https://kamaiops.github.io/join#$invite');
    final read = splitz.readScan(shared.last);
    expect(read, isA<splitz.ScannedInvite>());
    expect(
      (read as splitz.ScannedInvite).invite.key,
      (splitz.readScan(invite) as splitz.ScannedInvite).invite.key,
    );
    // The code drawn is the link too: a camera hands a custom scheme to
    // whichever app claims it.
    final drawn = t.widgetList<CodeImage>(
      find.byType(CodeImage, skipOffstage: false),
    );
    expect(drawn.map((q) => q.value), contains(shared.last));
    expect(drawn.map((q) => q.value), isNot(contains(invite)));
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
