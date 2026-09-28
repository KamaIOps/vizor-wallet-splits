/// The sentences this wallet writes for a split form.
///
/// `package:splitz_host` names a refusal by its §12 code and writes no
/// sentence for it, so these are ours and are asserted here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

void main() {
  test('every kind has a name a person can read', () {
    for (final kind in SplitKind.values) {
      expect(splitKindLabel(kind), isNotEmpty);
    }
  });

  test('a refusal carries the figures the code does not', () {
    final draft = SplitDraft(
      kind: SplitKind.exact,
      amounts: {'ana': 6000, 'ben': 2000},
    );
    expect(
      splitRefusalSentence(draft, 9000, currency: 'EUR'),
      contains('80.00 EUR'),
    );
    expect(
      splitRefusalSentence(draft, 9000, currency: 'EUR'),
      contains('90.00 EUR'),
    );
  });

  test('percentages are rendered without a double touching them', () {
    final draft = SplitDraft(
      kind: SplitKind.percentage,
      basisPoints: {'ana': 3000, 'ben': 6000},
    );
    expect(
      splitRefusalSentence(draft, 9000, currency: 'EUR'),
      contains('90.00%'),
    );
  });

  test('a split the protocol accepts has nothing to say', () {
    final draft = SplitDraft(kind: SplitKind.equal, among: {'ana', 'ben'});
    expect(splitRefusalSentence(draft, 9000, currency: 'EUR'), isNull);
  });

  test('a code with no sentence of its own still says the code', () {
    // Better than guessing a friendly wording for a fault. Two shares of
    // i64::MAX overflow their sum, and `weight_sum_overflow` is not one of
    // the codes named above.
    final draft = SplitDraft(
      kind: SplitKind.shares,
      shareCounts: {'ana': 9223372036854775807, 'ben': 9223372036854775807},
    );
    expect(draft.refusalCode(9000), 'weight_sum_overflow');
    expect(
      splitRefusalSentence(draft, 9000, currency: 'EUR'),
      contains('weight_sum_overflow'),
    );
  });
}
