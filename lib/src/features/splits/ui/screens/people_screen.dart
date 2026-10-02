/// Who is on the bill, and how each of them is paid.
///
/// Two different things live here and are not interchangeable. A participant
/// with a **bound identity** (§10.7) signed their own join and claimed a key
/// in it; nobody else can write as them. A participant without one is a name
/// to split an expense against and nothing more, and anyone on the bill can
/// write as them.
///
/// The screen reports the second, not how somebody got there: a join carrying
/// no key is indistinguishable from a name typed here, and claiming to tell
/// them apart would be claiming to know something the log does not say.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/host.dart' as hostapi;
import 'package:splitz_core/splitz_core.dart' as protocol;

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import '../view/naming.dart';
import '../view/removal_words.dart';
import 'payout_screen.dart';
import 'share_bill_screen.dart';
import 'text_entry_screen.dart';
import 'splits_scope.dart';

class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key, required this.billId});

  final String billId;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> with SplitsActions {
  String get billId => widget.billId;

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills.where((b) => b.id == billId).firstOrNull;
    if (view == null) {
      return const Scaffold(body: Center(child: Text('This bill is gone')));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('People')),
      bottomNavigationBar: BottomActions(
        children: [
          FilledButton(
            key: const Key('splits_people_add'),
            onPressed: () => _add(context, view),
            child: const Text('Add someone'),
          ),
          SecondaryButton(
            key: const Key('splits_people_invite'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ShareBillScreen(billId: billId),
              ),
            ),
            child: const Text('Invite someone'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Above the list, not after it: a list long enough to scroll
          // builds its end only when reached, and a refusal nobody sees makes
          // the tap look as if it did nothing.
          if (failure case final failed?)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                failed,
                key: const Key('splits_people_error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          for (final p in view.bill.participants)
            _PersonTile(
              billId: billId,
              view: view,
              participant: p,
              isMe: p.id == controller.me,
            ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context, BillView view) =>
      askAndAddPerson(context, billId: billId, view: view);
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({
    required this.billId,
    required this.view,
    required this.participant,
    required this.isMe,
  });

  final String billId;
  final BillView view;
  final protocol.Participant participant;
  final bool isMe;

  /// Whether §10.7 bound a key to this participant.
  bool get _bound => view.identities.bound.containsKey(participant.id);

  /// How they are paid, in a line. The FIRST preference, which is the one
  /// that decides the lane (§9.1).
  String get _payout {
    return switch (hostapi.laneFor(participant)) {
      hostapi.SettleLane.zec => 'Gets paid in ZEC',
      hostapi.SettleLane.swap =>
        'Gets paid in '
            '${participant.payouts.first.asset ?? 'another asset'} on '
            '${participant.payouts.first.chain ?? 'another chain'}',
      hostapi.SettleLane.cash => 'Gets paid in cash',
      hostapi.SettleLane.none =>
        'Hasn’t said how to get paid, so nobody can pay them yet',
    };
  }

  Future<void> _remove(BuildContext context) =>
      confirmAndRemovePerson(context, billId: billId, participant: participant);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RowCard(padding: EdgeInsets.zero, child: _tile(context, scheme));
  }

  Widget _tile(BuildContext context, ColorScheme scheme) {
    final lane = hostapi.laneFor(participant);
    final name = view.bill.displayNameOf(
      participant.id,
      creatorId: view.creatorId,
    );
    // Offered where there is something to do about it, instead of a sentence
    // saying what is missing. An address is theirs to set once they have
    // joined from their own phone (§10.7), so only an unbound record gets one
    // from here. One already set can be changed; a payer is warned about the
    // change before settling to it (§10.3).
    final hasWay = lane != hostapi.SettleLane.none;
    final actions = <Widget>[
      if (!isMe && !_bound)
        TextButton.icon(
          key: Key(
            hasWay
                ? 'splits_person_change_address_${participant.id}'
                : 'splits_person_add_address_${participant.id}',
          ),
          icon: Icon(
            hasWay ? Icons.edit_outlined : Icons.qr_code_scanner,
            size: 18,
          ),
          label: Text(hasWay ? 'Change address' : 'Add address'),
          onPressed: () => askAndSetAddress(
            context,
            billId: billId,
            id: participant.id,
            name: name,
          ),
        ),
      if (!isMe && !_bound)
        TextButton.icon(
          key: Key('splits_person_invite_${participant.id}'),
          icon: const Icon(Icons.link, size: 18),
          label: const Text('Invite'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ShareBillScreen(billId: billId),
            ),
          ),
        ),
    ];
    return Padding(
      key: Key('splits_person_${participant.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The name wraps rather than ending in an ellipsis: two people
                // whose names share a long start are otherwise one row twice.
                Row(
                  children: [
                    Flexible(child: Text(name)),
                    if (isMe)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Text('(you)'),
                      ),
                  ],
                ),
                if (lane != hostapi.SettleLane.none)
                  Text(
                    _payout,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                if (actions.isNotEmpty) Wrap(spacing: 4, children: actions),
              ],
            ),
          ),
          if (isMe)
            IconButton(
              key: const Key('splits_person_payout'),
              tooltip: 'How you get paid',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PayoutScreen(billId: billId),
                ),
              ),
            )
          // §10.8 lets the bill's creator withdraw somebody else's join, and
          // nobody else.
          else if (SplitsScope.of(context).me == view.creatorId)
            IconButton(
              key: Key('splits_person_remove_${participant.id}'),
              tooltip: 'Take off the bill',
              icon: const Icon(Icons.person_remove_outlined),
              // Not while a write is on its way: a removal planned before it
              // lands is planned against a bill about to change.
              onPressed: SplitsScope.of(context).busy
                  ? null
                  : () => _remove(context),
            ),
        ],
      ),
    );
  }
}

/// Asks for a name and puts that person on the bill.
///
/// The name reaches every device on the bill. They are added unbound (§10.7)
/// until they join from their own device.
Future<void> askAndAddPerson(
  BuildContext context, {
  required String billId,
  required BillView view,
}) async {
  final controller = SplitsScope.read(context);
  final act = actionsOf(context);
  final name = await askForText(
    context,
    title: 'Add a person',
    hint: 'Their name',
    action: 'Add',
    fieldKey: const Key('splits_people_name'),
    actionKey: const Key('splits_people_name_ok'),
  );
  if (name == null || name.trim().isEmpty) return;
  await act(
    () => controller.addPerson(
      billId: billId,
      id: _idFor(name.trim(), view),
      name: name.trim(),
    ),
  );
}

/// Takes [participant] off the bill, after saying what that needs.
///
/// Somebody an expense still names cannot come off (§10.8). Where this
/// device wrote those expenses and they only shared the cost, it offers to
/// take them out of every one first, the others sharing their part; what it
/// cannot change is said, with who can.
Future<void> confirmAndRemovePerson(
  BuildContext context, {
  required String billId,
  required protocol.Participant participant,
}) async {
  final controller = SplitsScope.read(context);
  final act = actionsOf(context);
  final view = controller.bills.where((b) => b.id == billId).firstOrNull;
  if (view == null) return;
  final plan = await controller.removalPlan(billId, participant.id);
  if (plan == null || !context.mounted) return;
  final name = participant.name;
  final edits = plan.edits.length;
  final blocked = plan.blockers.isNotEmpty;
  // §10.4: an expense is corrected only by whoever wrote it, and the one
  // written in its place is this device's.
  final taken = [
    for (final e in plan.edits)
      if (e.author != null && e.author != controller.me)
        '${removalEditName(e)} becomes yours to correct, not '
            '${view.bill.displayNameOf(e.author!, creatorId: view.creatorId)}’s.',
  ];

  final choice = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('Take $name off the bill?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!plan.namesThem)
              const Text('They’re on no expense or payment.')
            else ...[
              if (edits > 0)
                Text(
                  'They’ll come off ${edits == 1 ? '1 expense' : '$edits expenses'}, '
                  'and the others on ${edits == 1 ? 'it' : 'each'} share their part.',
                ),
              for (final t in taken)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('• $t'),
                ),
              if (blocked) ...[
                if (edits > 0) const SizedBox(height: 12),
                const Text('These still name them:'),
                for (final b in plan.blockers)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '• ${removalBlockerSentence(b, bill: view.bill, creatorId: view.creatorId)}',
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(null),
          child: Text(blocked && edits == 0 ? 'OK' : 'Keep them'),
        ),
        if (!plan.namesThem)
          FilledButton(
            key: const Key('splits_people_remove_confirm'),
            onPressed: () => Navigator.of(dialog).pop('remove'),
            child: const Text('Take them off'),
          )
        else if (edits > 0)
          FilledButton(
            key: const Key('splits_people_remove_all'),
            onPressed: () => Navigator.of(dialog).pop('edit'),
            child: Text(
              blocked
                  ? 'Remove from the ${edits == 1 ? 'one' : '$edits'} I can'
                  : 'Remove from all expenses',
            ),
          ),
      ],
    ),
  );
  if (choice == null) return;
  if (choice == 'edit') {
    final restated = await act(
      () => controller.restateExpenses(
        billId: billId,
        without: participant.id,
        confirmed: plan,
      ),
    );
    if (!restated) return;
    // Off the bill only once nothing else names them.
    if (blocked) return;
  }
  await act(() => controller.removePerson(billId: billId, id: participant.id));
}

/// An id for somebody being added by hand.
///
/// Derived from the name so the log reads plainly, and suffixed until it is
/// free: §9.1 refuses a duplicate, and two people called Sam are ordinary.
String _idFor(String name, BillView view) {
  final base = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final stem = base.isEmpty ? 'person' : base;
  var candidate = stem;
  var n = 1;
  while (view.bill.participant(candidate) != null) {
    n++;
    candidate = '$stem-$n';
  }
  return candidate;
}
