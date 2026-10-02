/// What taking somebody off a bill needs first, and what of it this device
/// can do (§10.3, §10.8).
///
/// A person comes off a bill only once no expense or payment names them.
/// This device can take them out of an expense where they only shared the
/// cost, when it wrote that expense or opened the bill; one the person paid
/// for, or a payment naming them, is not theirs to leave.
library;

import 'dart:convert';

import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;

import 'naming.dart';

/// One expense to write again without the person, withdrawing [entryId].
class RemovalEdit {
  const RemovalEdit({
    required this.entryId,
    required this.description,
    required this.seen,
    required this.author,
    required this.split,
  });

  final String entryId;
  final String description;

  /// The expense as the plan read it. What is written again is this, under
  /// [split]: payer, amount and description come from the same reading.
  final protocol.Expense seen;

  /// Who wrote the expense being withdrawn. The expense written in its place
  /// is this device's, and only its author may correct an expense (§10.4).
  final String? author;

  final Map<String, dynamic> split;
}

class RemovalPlan {
  const RemovalPlan({required this.edits, required this.blockers});

  /// Expenses this device can take them out of.
  final List<RemovalEdit> edits;

  /// What still names them once [edits] are written, each as a sentence.
  final List<String> blockers;

  bool get namesThem => edits.isNotEmpty || blockers.isNotEmpty;

  /// Whether [other] writes exactly what this does and is held back by the
  /// same things: what a person confirmed is still what would be written.
  bool sameAs(RemovalPlan other) => _fingerprint(this) == _fingerprint(other);

  static String _fingerprint(RemovalPlan plan) => jsonEncode({
    'edits': [
      for (final e in plan.edits)
        [
          e.entryId,
          e.seen.id,
          e.seen.paidBy,
          e.seen.amount,
          e.seen.description,
          e.seen.split,
          e.split,
        ],
    ],
    'blockers': plan.blockers,
  });
}

/// [split] without [id] in it, the others sharing what was theirs, or null
/// when that leaves nobody or needs a choice only a person can make: exact
/// amounts and percentages must still add up, an item they alone had
/// belongs to nobody else, and shares that leave nobody a share divide
/// nothing (§4.4).
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
      final total = counts.values.fold<int>(
        0,
        (sum, n) => sum + (n is int ? n : 0),
      );
      return total <= 0 ? null : {...split, 'shareCounts': counts};
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
  bool keyed(Object? figures) =>
      ((figures as Map?) ?? const {}).containsKey(id);
  return switch (split['type']) {
    'equal' => listed(split['among']),
    'exact' => keyed(split['amounts']),
    'percentage' => keyed(split['basisPoints']),
    'shares' => keyed(split['shareCounts']),
    'itemized' => ((split['items'] as List?) ?? const []).any(
      (item) => item is Map && listed(item['sharedBy']),
    ),
    _ => false,
  };
}

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

/// Whether an expense payload as a peer wrote it names [id], read the way
/// §10.8's check reads it: as payer, or under any member of its split,
/// whatever its `type` says.
bool _expenseNames(Map<String, dynamic> expense, String id) {
  if (expense['paidBy'] == id) return true;
  final split = _map(expense['split']);
  List<Object?> list(Object? v) => v is List ? v : const [];
  bool keyed(Object? v) => v is Map && v.containsKey(id);
  return list(split['among']).contains(id) ||
      keyed(split['amounts']) ||
      keyed(split['basisPoints']) ||
      keyed(split['shareCounts']) ||
      list(
        split['items'],
      ).any((item) => item is Map && list(item['sharedBy']).contains(id));
}

/// What taking [id] off a bill needs, as seen from [me].
///
/// [folded] is [log] folded. §10.8 counts somebody as named by every entry
/// still in force — an expense or payment the fold set aside included — and
/// by an amended entry when either the amendment or the entry it corrects
/// names them, so both are read here; reading the folded bill alone tells a
/// person somebody edited out of an expense is on nothing, and the removal is
/// then refused.
RemovalPlan planRemoval({
  required splitz.FoldedBill folded,
  required String creatorId,
  required List<Map<String, dynamic>> log,
  required String id,
  required String me,
}) {
  final bill = folded.bill;
  String name(String who) => bill.displayNameOf(who, creatorId: creatorId);
  final gone = folded.withdrawn.toSet();
  final byId = {for (final e in log) e['id']: e};

  // The amendment §10.4 applies to each entry: the last in log order whose
  // author wrote its target, carrying the target's kind and subject — and
  // none when that one is withdrawn, since an earlier one does not stand in
  // for it (§10.8).
  final amended = <String, Map<String, dynamic>>{};
  for (final e in log) {
    if (e['kind'] != 'amendEntry') continue;
    final target = byId[e['targetId']];
    if (target == null || e['author'] != target['author']) continue;
    final member = protocol.payloadForKind[target['kind']];
    if (member == null || e[member] is! Map) continue;
    if (_map(e[member])['id'] != _map(target[member])['id']) continue;
    amended[e['targetId'] as String] = e;
  }
  amended.removeWhere((_, e) => gone.contains(e['id']));
  List<Map<String, dynamic>> readings(Map<String, dynamic> e, String member) =>
      [_map(e[member]), _map(amended[e['id']]?[member])];

  final edits = <RemovalEdit>[];
  final blockers = <String>[];
  // One reading per entry, not per copy: §10.2's union keeps copies of an id
  // under different signatures, and an expense restated once per copy would
  // be on the bill twice.
  final read = <Object?>{};
  for (final entry in log) {
    if (gone.contains(entry['id']) || !read.add(entry['id'])) continue;
    switch (entry['kind']) {
      case 'addExpense':
        if (!readings(entry, 'expense').any((x) => _expenseNames(x, id))) {
          continue;
        }
        final e = bill.expenses
            .where((x) => folded.expenseEntries[x.id] == entry['id'])
            .firstOrNull;
        if (e == null) {
          final written = _map(entry['expense'])['description'];
          final what = written is String && written.isNotEmpty
              ? written
              : 'An expense';
          blockers.add(
            '$what can’t be applied to the bill and still names them.',
          );
          continue;
        }
        final what = e.description.isEmpty ? 'an expense' : e.description;
        if (e.paidBy == id) {
          blockers.add('They paid for $what.');
          continue;
        }
        final author = folded.expenseAuthors[e.id];
        // §10.8: an expense's author or the bill's creator may withdraw it.
        if (author != me && me != creatorId) {
          blockers.add(
            '$what was added by '
            '${author == null ? 'someone else' : name(author)}, '
            'who can take them out of it.',
          );
          continue;
        }
        // Named only by the entry it corrects: written again as it reads now.
        final split = _names(e.split, id) ? splitWithout(e.split, id) : e.split;
        if (split == null) {
          blockers.add('$what needs its split changed by hand.');
          continue;
        }
        edits.add(
          RemovalEdit(
            entryId: entry['id'] as String,
            description: what,
            seen: e,
            author: author,
            split: split,
          ),
        );
      case 'recordPayment':
        final payer = readings(entry, 'payment').any((x) => x['from'] == id);
        final payee = readings(entry, 'payment').any((x) => x['to'] == id);
        if (payer || payee) {
          blockers.add(
            'A payment ${payer ? 'from' : 'to'} them is on the bill.',
          );
        }
      case 'confirmPayment':
        if (entry['author'] == id) {
          blockers.add('They confirmed a payment.');
        }
    }
  }
  return RemovalPlan(edits: edits, blockers: blockers);
}
