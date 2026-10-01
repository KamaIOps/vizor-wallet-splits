/// The bills this device holds.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;

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
          if (controller.lastError != null)
            _Banner(message: controller.lastError!),
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
              MaterialPageRoute<void>(builder: (_) => const ScanBillScreen()),
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
    final balances = protocol.netBalances(view.bill);
    final mine = balances[controller.me] ?? 0;
    final people = view.bill.participants.length;
    final expenses = view.bill.expenses.length;

    return RowCard(
      key: Key('splits_bill_row_${view.id}'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => BillScreen(billId: view.id)),
      ),
      child: CardLine(
        leading: const Icon(Icons.receipt_long_outlined),
        title: view.bill.name.isEmpty ? 'Bill' : view.bill.name,
        subtitle: Text(
          '$people ${people == 1 ? 'person' : 'people'} · '
          '$expenses ${expenses == 1 ? 'expense' : 'expenses'}',
        ),
        // What this device is owed, or owes. Both directions read the same
        // way, so the sign is the whole message and is never dropped.
        trailing: mine == 0
            ? 'settled'
            : mine > 0
            ? 'owed ${formatAmount(mine, view.bill.currency)}'
            : 'owes ${formatAmount(-mine, view.bill.currency)}',
      ),
    );
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
    return RowCard(
      key: const Key('splits_totals'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in standings)
            CardLine(
              // One person may stand on two rows in one currency, when a
              // bill's figures could not be added to the rest: the bills
              // make each row's key its own.
              key: Key(
                'splits_total_${s.withId}_${s.currency}_${s.billIds.join(',')}',
              ),
              title: _nameOf(controller, s),
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
