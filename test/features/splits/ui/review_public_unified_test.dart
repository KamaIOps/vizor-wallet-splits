// §9.1, §14.2: a Unified Address §8.6 refuses — a P2PKH receiver beside a
// typecode §8.6 does not know, nothing shielded — is one the wallet pays
// transparently, so the review says the payment is public, as it does for a
// t1 address, and never for a Unified Address with a shielded receiver.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/screen_harness.dart';

/// UA{P2PKH, typecode 0x05}, mainnet.
const _refusedUnified =
    'u1e67lmu7s8etun46sslprau5u5z7v2ffd6p6wwp9xxxga86m9skaslmkptgyxlnewgxvym66jke59fp0np8rhmy0lrrympgy2hm33h0tjkxmg2mc4dcks57s9wm';
const _t1 = 't1eEvd4gkYDW8vUSbDxTe9VtarYFNdoB49q';

/// A Unified Address §8.6 decodes, with a shielded receiver.
const _shieldedUnified =
    'u1ddnjsdcpm36r6aq79n3s68shjweksnmwtdltrh046s8m6xcws9ygyawalxx8n6hg6vegk0wh8zjnafxgh6msppjsljvyt0ynece3lvm0';

/// The review's text for a bill owing Eve at [address], and what the kit
/// finds on it with and without the public words.
Future<(List<String>, List<ReviewFinding>, List<ReviewFinding>)> _review(
  WidgetTester t,
  String address,
) async {
  final c = controllerWith();
  late String id;
  await t.runAsync(
    () async => id = await owing(c, [
      (id: 'eve', name: 'Eve', address: address, owe: 50000),
    ]),
  );
  await t.pumpWidget(host(c, SettleScreen(billId: id)));
  await t.pumpAndSettle();
  await openReview(t);
  final shown = [
    for (final w in t.widgetList<Text>(
      find.descendant(
        of: find.byKey(const Key('splits_review')),
        matching: find.byType(Text),
      ),
    ))
      w.data ?? w.textSpan?.toPlainText() ?? '',
  ];
  final owed = (await t.runAsync(() => c.obligation(id)))!;
  List<ReviewFinding> kit(List<String> text) => checkPayerReview(
    obligation: owed,
    folded: c.bills.single.folded!,
    visibleText: text,
    reasonWords: const {},
    publicWords: publicPaymentWords,
  );
  return (
    shown,
    kit(shown),
    kit([
      for (final s in shown)
        if (s != publicPaymentWords) s,
    ]),
  );
}

void main() {
  testWidgets('a Unified Address §8.6 refuses is said to be public', (t) async {
    final (shown, found, withoutWords) = await _review(t, _refusedUnified);
    expect(shown, contains(publicPaymentWords));
    expect(zecLane(_refusedUnified), 'Transparent ZEC');
    expect(found, isEmpty);
    expect([for (final f in withoutWords) f.rule], [ReviewRule.publicOutput]);
  });

  testWidgets('so is a t1 address', (t) async {
    final (shown, found, _) = await _review(t, _t1);
    expect(shown, contains(publicPaymentWords));
    expect(zecLane(_t1), 'Transparent ZEC');
    expect(found, isEmpty);
  });

  testWidgets('a Unified Address with a shielded receiver is not', (t) async {
    final (shown, found, _) = await _review(t, _shieldedUnified);
    expect(shown, isNot(contains(publicPaymentWords)));
    expect(zecLane(_shieldedUnified), 'Shielded ZEC');
    expect(found, isEmpty);
  });
}
