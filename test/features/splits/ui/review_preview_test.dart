// The send review asks the wallet what the request would take before the
// payer confirms: the fee, or that the account cannot cover it.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

String? _text(WidgetTester t, String key) {
  final found = find.byKey(Key(key));
  return found.evaluate().isEmpty ? null : t.widget<Text>(found).data;
}

FilledButton _send(WidgetTester t) =>
    t.widget<FilledButton>(find.byKey(const Key('splits_review_send')));

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
    expect(_send(t).onPressed, isNotNull);
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
