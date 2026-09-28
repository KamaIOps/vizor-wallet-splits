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
import 'payout_screen.dart';
import 'share_bill_screen.dart';
import 'splits_scope.dart';

class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key, required this.billId});

  final String billId;

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
          for (final p in view.bill.participants)
            _PersonTile(
              billId: billId,
              view: view,
              participant: p,
              isMe: p.id == controller.me,
            ),
          if (controller.lastError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                controller.lastError!,
                key: const Key('splits_people_error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
    return ListTile(
      key: Key('splits_person_${participant.id}'),
      title: Row(
        children: [
          // A name comes from whatever a peer put in its join, and a
          // participant nobody has renamed is named by its id — long enough to
          // push the badge off the row. The name gives way; the badge does
          // not, because it is what says which row is this device's.
          Flexible(
            child: Text(
              view.bill.displayNameOf(
                participant.id,
                creatorId: view.creatorId,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isMe)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text('(you)'),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_payout),
          if (!_bound)
            Text(
              // What this can actually tell, which is narrower than how they
              // got here: §10.7 binds a key only to a join its own author
              // signed and claimed. A join carrying no key is
              // indistinguishable from a name somebody typed, so the sentence
              // says the thing that is true of both.
              'Hasn’t joined from their own phone yet. Until they do, '
              'anyone on the bill can add entries in their name.',
              style: TextStyle(color: scheme.error),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: isMe
          ? IconButton(
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
          // nobody else: offered to anyone else, it is a button that only
          // ever fails.
          : SplitsScope.of(context).me == view.creatorId
          ? IconButton(
              key: Key('splits_person_remove_${participant.id}'),
              tooltip: 'Take off the bill',
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: () => _remove(context),
            )
          : null,
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
  final name = await showDialog<String>(
    context: context,
    builder: (dialog) => const _NameSheet(),
  );
  if (name == null || name.trim().isEmpty) return;
  await controller.addPerson(
    billId: billId,
    id: _idFor(name.trim(), view),
    name: name.trim(),
  );
}

/// Takes [participant] off the bill, after saying what that needs.
Future<void> confirmAndRemovePerson(
  BuildContext context, {
  required String billId,
  required protocol.Participant participant,
}) async {
  final controller = SplitsScope.read(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('Take ${participant.name} off the bill?'),
      // Says the rule rather than letting it arrive as a refusal: §10.8
      // will not remove somebody an expense still names.
      content: const Text(
        'This only works while nothing on the bill still names them. If '
        'they paid for something or share an expense, take those off '
        'first.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Keep them'),
        ),
        FilledButton(
          key: const Key('splits_people_remove_confirm'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: const Text('Take them off'),
        ),
      ],
    ),
  );
  if (confirmed ?? false) {
    await controller.removePerson(billId: billId, id: participant.id);
  }
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

class _NameSheet extends StatefulWidget {
  const _NameSheet();

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Who is joining?'),
    content: TextField(
      key: const Key('splits_people_name'),
      controller: _name,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Their name'),
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('splits_people_name_ok'),
        onPressed: () => Navigator.of(context).pop(_name.text),
        child: const Text('Add them'),
      ),
    ],
  );
}
