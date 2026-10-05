// The send review asks the wallet what the request would take before the
// payer confirms: the fee, or that the account cannot cover it.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_button.dart';
import 'package:zcash_wallet/src/core/widgets/full_address_viewer.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_address_verify_sheet.dart';
import 'package:zcash_wallet/src/core/widgets/review_list_row.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'settle_send_test.dart' show app, owingBen;
import 'support/fake_wallet.dart';

SplitsController _controller(PreviewSend preview) => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  previewSend: preview,
);

Future<void> _openReview(WidgetTester t, SplitsController c, String id) async {
  await t.pumpWidget(app(c, SettleScreen(billId: id)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('splits_settle_send')));
  await t.pumpAndSettle();
  expect(find.byKey(const Key('splits_review')), findsOneWidget);
}

/// The text a keyed line shows, or null when it is not on the screen: a
/// wallet review row's value, or a plain line's text.
String? _text(WidgetTester t, String key) {
  final found = find.byKey(Key(key));
  if (found.evaluate().isEmpty) return null;
  final w = t.widget(found);
  return w is ReviewListRow ? w.value : (w as Text).data;
}

AppButton _send(WidgetTester t) =>
    t.widget<AppButton>(find.byKey(const Key('splits_review_send')));

void main() {
  testWidgets('the fee the wallet would pay is on the review', (t) async {
    final asked = <String>[];
    final c = _controller((uri) async {
      asked.add(uri);
      return const SendPreview(feeZatoshi: 10000);
    });
    final id = await owingBen(c);
    await _openReview(t, c, id);

    // The request the review shows is the one the wallet was asked about.
    expect(asked, [(await c.obligation(id))!.uri]);
    expect(_text(t, 'splits_review_fee'), '0.0001 ZEC');
    expect(_text(t, 'splits_review_short'), isNull);
    expect(_send(t).onPressed, isNotNull);
  });

  testWidgets('an account short of the request and its fee is said', (t) async {
    final c = _controller(
      (_) async =>
          const SendPreview(short: true, haveZatoshi: 0, needZatoshi: 1010000),
    );
    final id = await owingBen(c);
    await _openReview(t, c, id);

    expect(
      _text(t, 'splits_review_short'),
      'Not enough ZEC: this needs 0.0101 ZEC including the fee, and the '
      'wallet has 0 ZEC.',
    );
    expect(_send(t).onPressed, isNull);
  });

  testWidgets('a short account with no figures is still said', (t) async {
    final c = _controller((_) async => const SendPreview(short: true));
    final id = await owingBen(c);
    await _openReview(t, c, id);

    expect(
      _text(t, 'splits_review_short'),
      'Not enough ZEC to cover this and its fee.',
    );
    expect(_send(t).onPressed, isNull);
  });

  testWidgets('Confirm & send waits for the wallet\'s answer', (t) async {
    final answer = Completer<SendPreview>();
    final c = _controller((_) => answer.future);
    final id = await owingBen(c);
    await t.pumpWidget(app(c, SettleScreen(billId: id)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_send')));
    await t.pumpAndSettle();
    expect(_send(t).onPressed, isNull);

    answer.complete(const SendPreview(feeZatoshi: 10000));
    await t.pumpAndSettle();
    expect(_send(t).onPressed, isNotNull);
  });

  testWidgets('a wallet that cannot answer leaves a review with neither', (
    t,
  ) async {
    final c = _controller((_) async => throw StateError('no wallet database'));
    final id = await owingBen(c);
    await _openReview(t, c, id);

    expect(_text(t, 'splits_review_fee'), isNull);
    expect(_text(t, 'splits_review_short'), isNull);
    // Said rather than left blank where the fee goes.
    expect(find.byKey(const Key('splits_review_fee_unknown')), findsOneWidget);
    expect(_send(t).onPressed, isNotNull);
  });

  testWidgets('a wallet still syncing holds the send and says why', (t) async {
    final c = _controller((_) async => const SendPreview(syncing: true));
    final id = await owingBen(c);
    await _openReview(t, c, id);

    expect(find.byKey(const Key('splits_review_fee_syncing')), findsOneWidget);
    expect(find.text('Wallet is syncing'), findsOneWidget);
    expect(_send(t).onPressed, isNull);
  });

  testWidgets('Show full address opens the wallet\'s own address sheet', (
    t,
  ) async {
    final c = _controller((_) async => const SendPreview(feeZatoshi: 10000));
    final id = await owingBen(c);
    // As the wallet hosts the feature: its theme above every route, the
    // sheet's included.
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(
          builder: (context, child) =>
              AppTheme(data: AppThemeData.light, child: child!),
          home: SettleScreen(billId: id),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_settle_send')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('splits_review_full_address_0')));
    await t.pumpAndSettle();
    final sheet = find.byType(MobileAddressVerifySheet);
    expect(sheet, findsOneWidget);
    expect(
      t.widget<MobileAddressVerifySheet>(sheet).address,
      'u1benpayable0000000001',
    );
    expect(t.widget<MobileAddressVerifySheet>(sheet).title, 'ben');
    expect(
      find.descendant(of: sheet, matching: find.byType(FullAddressCopyButton)),
      findsOneWidget,
    );
  });

  test('the wallet\'s shortfall reads as zatoshi held and needed', () {
    expect(
      sendShortfall(
        'Propose failed: Insufficient balance (have 0, need 29610030 '
        'including fee)',
      ),
      (have: 0, need: 29610030),
    );
    expect(sendShortfall('Propose failed: no notes to spend'), isNull);
  });
}
