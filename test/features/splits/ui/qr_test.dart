/// Drawing a code, at the size the protocol says one can be.
///
/// §11.2 caps a scanned payload at what a version-40 QR holds in byte mode at
/// error correction M. That cap is only true if the renderer actually reaches
/// version 40 at level M — a renderer that stopped lower would refuse a
/// payload the protocol says fits, and the two limits would disagree with
/// nothing to say so.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:splitz_core/splitz_core.dart' as splitz;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController controllerFor(FakeWallet wallet) => SplitsController(
  wallet: wallet,
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

Widget app(SplitsController c, Widget home) => SplitsScope(
  controller: c,
  child: MaterialApp(home: home),
);

void main() {
  testWidgets('a payload at the protocol cap draws', (t) async {
    // §11.2 caps the body behind the prefix, and leaves room for the longer
    // prefix: the longest string the protocol produces is `splitzd1:` and a
    // body at the cap, which is what a version-40 code holds at level M.
    final atTheCap = 'splitzd1:${'A' * splitz.payloadCap}';
    expect(atTheCap.length, 2331);

    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: QrImageView(
            data: atTheCap,
            version: QrVersions.auto,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            size: 240,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    // A renderer that could not carry the data throws while painting, which
    // the test binding records. Nothing recorded means it drew.
    expect(
      t.takeException(),
      isNull,
      reason: 'the renderer stops short of the cap §11.2 states',
    );
  });

  testWidgets('one byte past the cap does NOT draw', (t) async {
    // The control for the test above: if a renderer drew this too, the cap
    // check would be passing for a reason unrelated to the cap.
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: QrImageView(
            data: 'A' * (2331 + 1),
            version: QrVersions.auto,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            size: 240,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(
      t.takeException(),
      isNotNull,
      reason: '§11.2 caps a payload at exactly what this renderer holds',
    );
  });

  _scannerTests();

  testWidgets('both codes are drawn, not just printed', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

    await t.pumpWidget(app(c, ShareBillScreen(billId: id)));
    await t.pumpAndSettle();

    // The whole bill first.
    expect(find.byKey(const Key('splits_qr_Bill code')), findsOneWidget);
    expect(find.text('Bill code'), findsOneWidget);

    // And the invite below it: they are not interchangeable, and a screen
    // showing one code leaves a reader guessing which they scanned.
    await t.scrollUntilVisible(
      find.text('Invite'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.pumpAndSettle();
    expect(find.text('Invite'), findsOneWidget);
    expect(find.byKey(const Key('splits_qr_Invite')), findsOneWidget);
    // And it can still be copied: a code that will not scan is still one
    // somebody can paste.
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.byKey(const Key('splits_qr_Invite')),
          matching: find.byType(Card),
        ),
        matching: find.byTooltip('Copy'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('every code has four modules of white around it', (t) async {
    // Tall enough that both cards are laid out at once.
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = controllerFor(FakeWallet());
    await c.load();
    final id = (await c.createBill(name: 'Dinner', currency: 'USD'))!;

    await t.pumpWidget(app(c, ShareBillScreen(billId: id)));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('Invite'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.pumpAndSettle();

    final codes = t.widgetList<QrImageView>(find.byType(QrImageView)).toList();
    // What each image carries.
    final texts = t
        .widgetList<CodeImage>(find.byType(CodeImage))
        .map((w) => w.value)
        .toList();
    expect(codes, hasLength(2));
    expect(texts, hasLength(2));
    for (final (i, code) in codes.indexed) {
      final modules = QrValidator.validate(
        data: texts[i],
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      ).qrCode!.moduleCount;
      final pad = code.padding.left;
      final module = (code.size! - 2 * pad) / modules;
      // ISO/IEC 18004's quiet zone; a small invite code is where a fixed
      // margin falls short.
      expect(
        pad / module,
        greaterThanOrEqualTo(4 - 1e-9),
        reason: '${texts[i].length} chars, $modules modules',
      );
      expect(code.padding.left, code.padding.top);
    }
    // Both codes carry the warning that sharing one cannot be undone.
    expect(find.byKey(const Key('splits_code_warning_Invite')), findsOneWidget);
  });
}

/// The camera the wallet supplies, and the build that supplies none.
void _scannerTests() {
  testWidgets('a build with no camera offers no scan button', (t) async {
    // Null is a state, not a failure: pasting works without a camera, and a
    // button leading nowhere is worse than none.
    final c = controllerFor(FakeWallet());
    await c.load();
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: const MaterialApp(home: ScanBillScreen()),
      ),
    );
    await t.pumpAndSettle();

    expect(find.byKey(const Key('splits_scan_camera')), findsNothing);
    expect(find.textContaining('Paste a bill code'), findsOneWidget);
  });

  testWidgets("the wallet's camera feeds the same reader as a paste", (
    t,
  ) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    final maker = controllerFor(FakeWallet(id: 'ben', payTo: 'u1ben'));
    await maker.load();
    final id = (await maker.createBill(name: 'Dinner', currency: 'USD'))!;
    final payload = await maker.shareableBill(id);

    var opened = 0;
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        scan: (_) async {
          opened++;
          return payload;
        },
        child: const MaterialApp(home: ScanBillScreen()),
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('splits_scan_camera')));
    await t.pumpAndSettle();
    expect(c.bills, isEmpty, reason: 'a scan is previewed, not taken');
    await t.tap(find.byKey(const Key('splits_scan_read')));
    await t.pumpAndSettle();

    expect(opened, 1);
    // The bill the camera read is now held here, by the same path a paste
    // would have taken.
    expect(c.bills.map((b) => b.id), contains(id));
  });

  testWidgets('backing out of the camera changes nothing', (t) async {
    final c = controllerFor(FakeWallet());
    await c.load();
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        scan: (_) async => null,
        child: const MaterialApp(home: ScanBillScreen()),
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('splits_scan_camera')));
    await t.pumpAndSettle();

    expect(c.bills, isEmpty);
    expect(c.lastError, isNull);
  });
}
