/// The bills this device holds.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart' show BillNaming, nameSkeleton;

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import '../view/naming.dart';
import 'arrivals_screen.dart';
import 'bill_screen.dart';
import 'new_bill_screen.dart';
import 'scan_bill_screen.dart';
import 'splits_scope.dart';

/// Every bill on this device, and the two ways in to another.
class BillsScreen extends StatelessWidget {
  const BillsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    // The feature runs in a navigator of its own, where this is the first
    // route. Leaving it pops whatever hosts that navigator.
    final host = Navigator.of(
      context,
    ).context.findAncestorStateOfType<NavigatorState>();
    return Scaffold(
      appBar: AppBar(
        leading: host != null && host.canPop()
            ? BackButton(onPressed: () => host.maybePop())
            : null,
        title: const Text('Split a bill'),
      ),
      body: Column(
        children: [
          // What reading the bills could not do: the list below is short
          // by it. A refusal elsewhere is shown where it was met.
          if (controller.loadError case final failed?) _Banner(message: failed),
          if (!controller.identityIsRecoverable) const _UnrecoverableIdentity(),
          Expanded(
            child: controller.bills.isEmpty
                ? const _Empty()
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      if (controller.arrived.isNotEmpty ||
                          controller.disputed.isNotEmpty ||
                          controller.underpriced.isNotEmpty ||
                          controller.unbound.isNotEmpty)
                        _Arrived(
                          count:
                              controller.arrived.length +
                              controller.disputed.length +
                              controller.underpriced.length +
                              controller.unbound.length,
                        ),
                      if (controller.bills.length > 1) const _Totals(),
                      for (final view in controller.bills)
                        _BillTile(view: view),
                    ],
                  ),
          ),
        ],
      ),
      bottomNavigationBar: BottomActions(
        children: [
          SecondaryButton(
            key: const Key('splits_join_bill'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: ScanBillScreen.routeName),
                builder: (_) => const ScanBillScreen(),
              ),
            ),
            child: const Text('Join a bill'),
          ),
          FilledButton(
            key: const Key('splits_start_bill'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const NewBillScreen()),
            ),
            child: const Text('Start a bill'),
          ),
        ],
      ),
    );
  }
}

class _BillTile extends StatelessWidget {
  const _BillTile({required this.view});

  final BillView view;

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final bill = view.bill;
    final balances = protocol.netBalances(bill);
    final mine = balances[controller.me] ?? 0;
    final people = bill.participants.length;
    final expenses = bill.expenses.length;
    // §14.4: what this device recorded and the payee has not confirmed is
    // still owed, and is also already on its way. Both are said.
    final sent = sentNotConfirmed(controller.sentOn(view.id), bill.currency);

    return RowCard(
      key: Key('splits_bill_row_${view.id}'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => BillScreen(billId: view.id)),
      ),
      child: CardLine(
        leading: const Icon(Icons.receipt_long_outlined),
        title: bill.name.isEmpty ? 'Bill' : bill.name,
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$people ${people == 1 ? 'person' : 'people'} · '
              '$expenses ${expenses == 1 ? 'expense' : 'expenses'}',
            ),
            if (sent != null)
              // Beside a figure that takes the room it needs, so a long one
              // here is drawn smaller rather than broken inside its digits.
              WholeWords(sent, key: Key('splits_bill_row_sent_${view.id}')),
          ],
        ),
        // What this device is owed, or owes. Both directions read the same
        // way, so the sign is the whole message and is never dropped.
        trailing: mine > 0
            ? 'owed ${formatAmount(mine, bill.currency)}'
            : mine < 0
            ? 'owes ${formatAmount(-mine, bill.currency)}'
            : _nothingOnMe(controller.me),
      ),
    );
  }

  /// What the row says when nothing stands on this device's own id.
  ///
  /// "settled" only when that is the whole story: a device not on the bill
  /// is not settled with anybody, and a participant going by this device's
  /// name who still owes or is owed may be this person entered by somebody
  /// else, whose debt is theirs in all but id.
  String _nothingOnMe(String me) {
    final bill = view.bill;
    final self = bill.participant(me);
    if (self == null) return 'not joined';
    if (self.name.trim().isEmpty) return 'settled';
    final balances = protocol.netBalances(bill);
    final skeleton = nameSkeleton(self.name);
    for (final p in bill.participants) {
      if (p.id == me || nameSkeleton(p.name) != skeleton) continue;
      final net = balances[p.id] ?? 0;
      if (net == 0) continue;
      final who = bill.displayNameOf(p.id, creatorId: view.creatorId);
      return net < 0
          ? '$who owes ${formatAmount(-net, bill.currency)}'
          : '$who is owed ${formatAmount(net, bill.currency)}';
    }
    return 'settled';
  }
}

/// Payments the wallet has received and nobody has confirmed yet.
class _Arrived extends StatelessWidget {
  const _Arrived({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => RowCard(
    key: const Key('splits_arrivals'),
    onTap: () => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ArrivalsScreen())),
    child: CardLine(
      leading: const Icon(Icons.call_received),
      title: count == 1 ? '1 payment received' : '$count payments received',
      subtitle: const Text('Check and confirm'),
      chevron: true,
    ),
  );
}

/// What this device and each person owe each other across every bill, one
/// line per person and currency.
class _Totals extends StatelessWidget {
  const _Totals();

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final totals = controller.totals;
    final standings = totals.standings.where((s) => s.net != 0).toList();
    // A bill the totals could not count is said, so an overall figure is
    // never read as covering every bill when it does not.
    final left = [
      for (final view in controller.bills)
        if (totals.uncounted.containsKey(view.id)) view.bill.name,
    ];
    if (standings.isEmpty && left.isEmpty) return const SizedBox.shrink();
    final names = _namesOf(controller, standings);
    return RowCard(
      key: const Key('splits_totals'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, s) in standings.indexed)
            CardLine(
              // One person may stand on two rows in one currency, when a
              // bill's figures could not be added to the rest: the bills
              // make each row's key its own.
              key: Key(
                'splits_total_${s.withId}_${s.currency}_${s.billIds.join(',')}',
              ),
              title: names[i],
              subtitle: s.sentAwaiting > 0
                  ? Text(
                      '${formatAmount(s.sentAwaiting, s.currency)} sent, '
                      'not yet confirmed',
                    )
                  : null,
              trailing: s.net > 0
                  ? 'owes you ${formatAmount(s.net, s.currency)}'
                  : 'you owe ${formatAmount(-s.net, s.currency)}',
            ),
          if (left.isNotEmpty)
            Padding(
              key: const Key('splits_totals_uncounted'),
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Not counted here: ${left.join(', ')}. Open '
                '${left.length == 1 ? 'it' : 'each'} to see what is owed.',
              ),
            ),
        ],
      ),
    );
  }

  /// The name they go by on the first bill that names them.
  static String _nameOf(SplitsController controller, splitz.Standing s) {
    for (final view in controller.bills) {
      if (!s.billIds.contains(view.id)) continue;
      return view.bill.displayNameOf(s.withId, creatorId: view.creatorId);
    }
    return s.withId;
  }

  /// A title for each of [standings], in order, no two alike.
  ///
  /// A name is qualified on one bill only against that bill's people, so two
  /// people called Ben on two bills are both plain "Ben". Rows that read
  /// alike are told apart by the bills they sum, then by the id's tail. One
  /// person's rows in two currencies are left plain: the currency already
  /// tells them apart, and they are the same person.
  static List<String> _namesOf(
    SplitsController controller,
    List<splitz.Standing> standings,
  ) {
    final names = [for (final s in standings) _nameOf(controller, s)];
    List<List<int>> alike() {
      final groups = <String, List<int>>{};
      for (final (i, name) in names.indexed) {
        groups.putIfAbsent(nameSkeleton(name), () => []).add(i);
      }
      return [
        for (final g in groups.values)
          if (g.length > 1 &&
              !(g.every((i) => standings[i].withId == standings[g[0]].withId) &&
                  {for (final i in g) standings[i].currency}.length ==
                      g.length))
            g,
      ];
    }

    String billNames(splitz.Standing s) => [
      for (final view in controller.bills)
        if (s.billIds.contains(view.id))
          view.bill.name.isEmpty ? 'Bill' : view.bill.name,
    ].join(', ');

    for (final g in alike()) {
      for (final i in g) {
        names[i] = '${names[i]} · ${billNames(standings[i])}';
      }
    }
    for (final g in alike()) {
      for (final i in g) {
        names[i] =
            '${names[i]} (${BillNaming.shortId(standings[i].withId, length: 8)})';
      }
    }
    return names;
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Text('No bills yet.', textAlign: TextAlign.center),
    ),
  );
}

/// Says when this account's signing identity could not be made recoverable.
///
/// The difference is invisible in every signature it makes and decisive the
/// day the device is replaced, so it is stated rather than left to be
/// discovered then.
class _UnrecoverableIdentity extends StatelessWidget {
  const _UnrecoverableIdentity();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.all(12),
    child: const Text('This account can’t be restored on a new phone.'),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.errorContainer,
    padding: const EdgeInsets.all(12),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
    ),
  );
}
