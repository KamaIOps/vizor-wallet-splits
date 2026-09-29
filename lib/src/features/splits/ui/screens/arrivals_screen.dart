/// Payments to this device that its wallet has already received.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;

import '../view/chrome.dart';
import '../view/naming.dart';
import 'splits_scope.dart';

/// Each payment the wallet received, as the payee must see it before
/// confirming (§14.2): who sent it, on which bill, what it settles, the ZEC
/// it says was sent, the rate it was priced at, and the transaction.
class ArrivalsScreen extends StatelessWidget {
  const ArrivalsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final arrived = controller.arrived;
    return Scaffold(
      appBar: AppBar(title: const Text('Payments received')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (controller.lastError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                controller.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (arrived.isEmpty) const Text('Nothing to confirm.'),
          for (final a in arrived) _Arrival(arrival: a),
        ],
      ),
      bottomNavigationBar: arrived.isEmpty
          ? null
          : BottomActions(
              children: [
                FilledButton(
                  key: const Key('splits_arrivals_confirm'),
                  onPressed: controller.busy
                      ? null
                      : () async {
                          await controller.confirmArrivals(arrived);
                          if (context.mounted && controller.lastError == null) {
                            Navigator.of(context).pop();
                          }
                        },
                  child: Text(
                    arrived.length == 1 ? 'Confirm it' : 'Confirm all',
                  ),
                ),
              ],
            ),
    );
  }
}

class _Arrival extends StatelessWidget {
  const _Arrival({required this.arrival});

  final splitz.Arrival arrival;

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills
        .where((b) => b.id == arrival.billId)
        .firstOrNull;
    final payment = arrival.payment;
    final from =
        view?.bill.displayNameOf(payment.from, creatorId: view.creatorId) ??
        payment.from;
    final rate = payment.paidAtRate;
    final zatoshi = payment.zatoshi;
    return RowCard(
      key: Key('splits_arrival_${arrival.billId}_${payment.id}'),
      child: CardLine(
        title: '$from · ${view?.bill.name ?? 'Bill'}',
        subtitle: Text(
          [
            if (zatoshi != null) '${protocol.renderAmount(zatoshi)} ZEC',
            if (rate != null)
              'at ${formatAmount(rate.minorUnitsPerZec, rate.currency)}/ZEC',
            'tx ${arrival.txid.substring(0, 8)}…',
          ].join(' · '),
        ),
        trailing: formatAmount(payment.amount, payment.currency),
      ),
    );
  }
}
