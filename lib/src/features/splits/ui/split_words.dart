/// The English a split form shows.
///
/// `package:splitz_host` names a split kind by its §4 discriminator and a
/// refusal by its §12 code, and writes no sentence for either: a sentence
/// there would be English only, and every wallet that is not in English would
/// carry a second one anyway. These are this wallet's.
library;

import 'package:splitz_core/splitz_core.dart' as splitz;
import 'package:splitz_host/splitz_host.dart';

import 'view/naming.dart';

/// What a person is shown for each of §4's five.
String splitKindLabel(SplitKind kind) => switch (kind) {
  SplitKind.equal => 'Equally',
  SplitKind.exact => 'Exact amounts',
  SplitKind.percentage => 'Percentages',
  SplitKind.shares => 'Shares',
  SplitKind.itemized => 'By item',
};

/// Why the protocol will not take [draft] yet, in words, or null when it will.
///
/// The figures come from the draft rather than from the refusal, because a
/// code carries no numbers: `percentage_not_full_scale` tells a person
/// nothing they can act on.
///
/// Amounts are written in [currency], as a person typed them: a sentence in
/// minor units reads "come to 5500, not 6000" to somebody who typed 55 and 60.
String? splitRefusalSentence(
  SplitDraft draft,
  int totalMinorUnits, {
  required String currency,
}) {
  final code = draft.refusalCode(totalMinorUnits);
  if (code == null) return null;
  String money(BigInt minorUnits) => minorUnits.isValidInt
      ? formatAmount(minorUnits.toInt(), currency)
      : '$minorUnits minor units';
  return switch (code) {
    splitz.SplitCode.emptySplit => 'Nobody is sharing this',
    splitz.SplitCode.exactTotalMismatch =>
      'The amounts come to ${money(_sum(draft.amounts.values))}, '
          'not ${money(BigInt.from(totalMinorUnits))}',
    splitz.SplitCode.percentageNotFullScale =>
      'The percentages come to ${_percent(_sum(draft.basisPoints.values))}, '
          'not 100%',
    splitz.SplitCode.zeroWeightSum => 'Somebody needs at least one share',
    splitz.SplitCode.negativeShare =>
      'A share cannot run the opposite way to the expense',
    splitz.SplitCode.itemizedNoItems => 'Add at least one item',
    splitz.SplitCode.itemizedUnassignedItem =>
      'Every item needs somebody who shared it',
    splitz.SplitCode.itemizedTotalMismatch =>
      'The items and extras come to '
          '${money(_sum([for (final i in draft.items) i.minorUnits, draft.extraMinorUnits]))}, '
          'not ${money(BigInt.from(totalMinorUnits))}',
    splitz.SplitCode.amountOverflow => 'Those figures are too large to add',
    splitz.SplitCode.unknownParticipant =>
      'Somebody named here is not on this bill',
    // Every other §12 code reaching a split form is a fault rather than a
    // typo, and saying so is better than guessing a friendly sentence for it.
    _ => 'This split cannot be used ($code)',
  };
}

/// The sum of typed figures, which may not fit in 64 bits: the protocol
/// refuses those, and the sentence still has to say what they came to.
BigInt _sum(Iterable<int> values) =>
    values.fold(BigInt.zero, (total, v) => total + BigInt.from(v));

/// Basis points as a percentage, without a double touching it.
String _percent(BigInt basisPoints) {
  final hundred = BigInt.from(100);
  final whole = basisPoints ~/ hundred;
  final fraction = (basisPoints % hundred).abs().toString().padLeft(2, '0');
  return '$whole.$fraction%';
}
