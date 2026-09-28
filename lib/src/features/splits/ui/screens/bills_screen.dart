/// The bills this device holds.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/splitz_core.dart' as protocol;

import '../state/splits_controller.dart';
import '../view/naming.dart';
import 'bill_screen.dart';
import 'new_bill_screen.dart';
import 'scan_bill_screen.dart';
import 'splits_scope.dart';

/// Every bill on this device, and the way in to a new one.
class BillsScreen extends StatelessWidget {
  const BillsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bills'),
        actions: [
          IconButton(
            tooltip: 'Scan a bill',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ScanBillScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const NewBillScreen())),
        icon: const Icon(Icons.add),
        label: const Text('New bill'),
      ),
      body: Column(
        children: [
          if (controller.lastError != null)
            _Banner(message: controller.lastError!),
          if (!controller.identityIsRecoverable) const _UnrecoverableIdentity(),
          Expanded(
            child: controller.bills.isEmpty
                ? const _Empty()
                : ListView.separated(
                    itemCount: controller.bills.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) =>
                        _BillTile(view: controller.bills[i]),
                  ),
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

    return ListTile(
      title: Text(view.bill.name.isEmpty ? 'Bill' : view.bill.name),
      subtitle: Text(
        '${view.bill.participants.length} people · '
        '${view.bill.expenses.length} expenses',
      ),
      trailing: Text(
        // What this device is owed, or owes. Both directions read the same
        // way, so the sign is the whole message and is never dropped.
        mine == 0
            ? 'settled'
            : mine > 0
            ? 'owed ${formatAmount(mine, view.bill.currency)}'
            : 'owes ${formatAmount(-mine, view.bill.currency)}',
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => BillScreen(billId: view.id)),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Text(
        'No bills yet.\n\n'
        'Open one and share the code, or scan somebody else’s.',
        textAlign: TextAlign.center,
      ),
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
    child: const Text(
      'This account signs with a key that cannot be restored from your '
      'recovery phrase. Bills you are on would not recognise you on a new '
      'device.',
    ),
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
