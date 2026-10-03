/// The words a person is shown for what taking somebody off a bill needs.
///
/// What names them, and what of it this device can change, is the host's
/// answer (`planRemoval`, §10.8); this is only how it reads.
library;

import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart';

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
