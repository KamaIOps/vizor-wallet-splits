/// What taking somebody off a bill needs first, and what of it this device
/// can do (§10.3, §10.8).
///
/// A person comes off a bill only once no expense or payment names them.
/// This device can take them out of an expense where they only shared the
/// cost, when it wrote that expense or opened the bill; one the person paid
/// for, or a payment naming them, is not theirs to leave.
library;

import '../state/splits_controller.dart';
import 'naming.dart';

/// One expense to rewrite without the person, as an amendment of [entryId].
class RemovalEdit {
  const RemovalEdit({
    required this.entryId,
    required this.description,
    required this.split,
  });

  final String entryId;
  final String description;
  final Map<String, dynamic> split;
}

class RemovalPlan {
  const RemovalPlan({required this.edits, required this.blockers});

  /// Expenses this device can take them out of.
  final List<RemovalEdit> edits;

  /// What still names them once [edits] are written, each as a sentence.
  final List<String> blockers;

  bool get namesThem => edits.isNotEmpty || blockers.isNotEmpty;
}

/// [split] without [id] in it, the others sharing what was theirs, or null
/// when that leaves nobody or needs a choice only a person can make: exact
/// amounts and percentages must still add up, and an item they alone had
/// belongs to nobody else.
Map<String, dynamic>? splitWithout(Map<String, dynamic> split, String id) {
  List<Object?> drop(Object? ids) => [
    for (final x in (ids as List?) ?? const [])
      if (x != id) x,
  ];
  switch (split['type']) {
    case 'equal':
      final among = drop(split['among']);
      return among.isEmpty ? null : {...split, 'among': among};
    case 'shares':
      final counts = Map<String, dynamic>.from(
        (split['shareCounts'] as Map?) ?? const {},
      )..remove(id);
      return counts.isEmpty ? null : {...split, 'shareCounts': counts};
    case 'itemized':
      final items = <Map<String, dynamic>>[];
      for (final raw in (split['items'] as List?) ?? const []) {
        final item = Map<String, dynamic>.from(raw as Map);
        final had = (item['sharedBy'] as List?) ?? const [];
        final left = drop(had);
        if (left.isEmpty && had.contains(id)) return null;
        items.add({...item, 'sharedBy': left});
      }
      return {...split, 'items': items};
    default:
      return null;
  }
}

bool _names(Map<String, dynamic> split, String id) {
  bool listed(Object? ids) => ((ids as List?) ?? const []).contains(id);
  return switch (split['type']) {
    'equal' => listed(split['among']),
    'exact' => ((split['amounts'] as Map?) ?? const {}).containsKey(id),
    'percentage' => ((split['basisPoints'] as Map?) ?? const {}).containsKey(
      id,
    ),
    'shares' => ((split['shareCounts'] as Map?) ?? const {}).containsKey(id),
    'itemized' => ((split['items'] as List?) ?? const []).any(
      (item) => listed((item as Map)['sharedBy']),
    ),
    _ => false,
  };
}

/// What taking [id] off [view]'s bill needs, as seen from [me].
RemovalPlan planRemoval(BillView view, String id, String me) {
  final bill = view.bill;
  String name(String who) => bill.displayNameOf(who, creatorId: view.creatorId);
  final edits = <RemovalEdit>[];
  final blockers = <String>[];
  for (final e in bill.expenses) {
    final what = e.description.isEmpty ? 'an expense' : e.description;
    if (e.paidBy == id) {
      blockers.add('They paid for $what.');
      continue;
    }
    if (!_names(e.split, id)) continue;
    final author = view.expenseAuthors[e.id];
    final entryId = view.expenseEntries[e.id];
    // §10.8: an expense's author or the bill's creator may withdraw it.
    if ((author != me && me != view.creatorId) || entryId == null) {
      blockers.add(
        '$what was added by ${author == null ? 'someone else' : name(author)}, '
        'who can take them out of it.',
      );
      continue;
    }
    final split = splitWithout(e.split, id);
    if (split == null) {
      blockers.add('$what needs its split changed by hand.');
      continue;
    }
    edits.add(RemovalEdit(entryId: entryId, description: what, split: split));
  }
  for (final p in bill.payments) {
    if (p.from == id || p.to == id) {
      blockers.add(
        'A payment ${p.from == id ? 'from' : 'to'} them is on the bill.',
      );
    }
  }
  return RemovalPlan(edits: edits, blockers: blockers);
}
