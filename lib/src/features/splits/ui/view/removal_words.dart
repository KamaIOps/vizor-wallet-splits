/// The words a person is shown for what taking somebody off a bill needs.
///
/// What names them, and what of it this device can change, is the host's
/// answer (`planRemoval`, §10.8); this is only how it reads.
library;

import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart';

import 'naming.dart' show formatAmount;

/// What [edit] restates, as a sentence names it.
String removalEditName(RemovalEdit edit) =>
    edit.seen.description.isEmpty ? 'an expense' : edit.seen.description;

/// [blocker] as one sentence, naming people the way [bill] does.
String removalBlockerSentence(
  RemovalBlocker blocker, {
  required protocol.Bill bill,
  required String creatorId,
}) {
  final what = blocker.description.isEmpty ? 'an expense' : blocker.description;
  return switch (blocker.block) {
    RemovalBlock.unapplied =>
      '${blocker.description.isEmpty ? 'An expense' : blocker.description} '
          'can’t be applied to the bill and still names them.',
    RemovalBlock.paidFor => 'They paid for $what.',
    RemovalBlock.addedByAnother =>
      '$what was added by '
          '${blocker.author == null ? 'someone else' : bill.displayNameOf(blocker.author!, creatorId: creatorId)}, '
          'who can take them out of it.',
    RemovalBlock.splitByHand => '$what needs its split changed by hand.',
    RemovalBlock.payment =>
      'A payment ${blocker.fromThem ? 'from' : 'to'} them is on the bill.',
    RemovalBlock.confirmation => 'They confirmed a payment.',
  };
}

/// [id] as the people list names them on [bill], with this device's own
/// participant ([me]) marked "(you)" whatever name it goes by.
///
/// The list's own name already stands in for an empty one (its id's tail),
/// so a removal never reads as nobody.
String removalPersonName(
  protocol.Bill bill,
  String id, {
  required String creatorId,
  required String me,
}) {
  final name = bill.displayNameOf(id, creatorId: creatorId);
  return id == me ? '$name (you)' : name;
}

/// What the person taken off is moving: their share of [expenses] expenses,
/// [share] minor units of [currency], stated by its size.
///
/// A share below zero is what a refund owed them, so it is said as money
/// they were to get back rather than as a negative share.
String removalShareHeadline(
  int share, {
  required String currency,
  required int expenses,
}) {
  final what = expenses == 1 ? '1 expense' : '$expenses expenses';
  return share < 0
      ? 'The ${formatAmount(-share, currency)} they were to get back from '
            '$what moves to the others:'
      : 'Their ${formatAmount(share, currency)} share of $what moves to the '
            'others:';
}

/// One person's share moving by [change] minor units of [currency]: by its
/// size, and "more" or "less" by its sign.
String removalShareChange(String who, int change, {required String currency}) =>
    '$who pays ${formatAmount(change.abs(), currency)} '
    '${change > 0 ? 'more' : 'less'}';
