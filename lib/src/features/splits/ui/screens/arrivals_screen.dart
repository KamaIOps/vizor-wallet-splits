/// Payments to this device that its wallet has already received.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import '../view/naming.dart';
import 'splits_scope.dart';

/// Each payment the wallet received, as the payee must see it before
/// confirming (§14.2): who sent it, on which bill, what it settles, the ZEC
/// it says was sent, the rate it was priced at, and the transaction.
///
/// A payment whose figures do not hold up is not in the one-tap confirm: the
/// ZEC it names worth less than it settles at the bill's own price, a price
/// the payer set, a record priced at another rate than the bill's, or one far
/// from the market. Each such payment is confirmed on its own, after the
/// person has read why.
class ArrivalsScreen extends StatefulWidget {
  const ArrivalsScreen({super.key});

  @override
  State<ArrivalsScreen> createState() => _ArrivalsScreenState();
}

class _ArrivalsScreenState extends State<ArrivalsScreen> {
  /// The live price per currency, once asked; null when none could be read.
  final Map<String, int?> _live = {};

  /// Currencies whose price has been asked for and has not answered. Nothing
  /// is confirmed in one tap meanwhile: the market check would be skipped
  /// for whoever taps first.
  final Set<String> _asking = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = SplitsScope.read(context);
    final currencies = {
      for (final a in controller.arrived) a.payment.currency,
    }.where((c) => !_live.containsKey(c)).toList();
    for (final currency in currencies) {
      _live[currency] = null;
      _asking.add(currency);
      controller
          .quoteZec(currency)
          .then(
            (price) {
              if (mounted) {
                setState(() {
                  _live[currency] = price;
                  _asking.remove(currency);
                });
              }
            },
            onError: (_) {
              if (mounted) setState(() => _asking.remove(currency));
            },
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final arrived = controller.arrived;
    final concerns = {
      for (final a in arrived)
        a: arrivalConcerns(
          arrival: a,
          view: controller.bills.where((b) => b.id == a.billId).firstOrNull,
          live: _live[a.payment.currency],
        ),
    };
    final plain = [
      for (final a in arrived)
        if (concerns[a]!.isEmpty) a,
    ];
    final asking = plain.any((a) => _asking.contains(a.payment.currency));
    final unread = {
      for (final a in plain)
        if (!_asking.contains(a.payment.currency) &&
            _live[a.payment.currency] == null)
          a.payment.currency,
    };
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
          if (arrived.isEmpty && controller.disputed.isEmpty)
            const Text('Nothing to confirm.'),
          if (unread.isNotEmpty)
            Padding(
              key: const Key('splits_arrivals_no_market'),
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Today\'s ZEC price in ${unread.join(', ')} could not be '
                'read, so these are checked against the bill\'s price only.',
              ),
            ),
          for (final a in arrived) _Arrival(arrival: a, concerns: concerns[a]!),
          for (final a in controller.disputed)
            _Arrival(
              arrival: a,
              concerns: const [disputedConcern],
              confirmable: false,
            ),
        ],
      ),
      bottomNavigationBar: plain.isEmpty
          ? null
          : BottomActions(
              children: [
                FilledButton(
                  key: const Key('splits_arrivals_confirm'),
                  onPressed: controller.busy || asking
                      ? null
                      : () async {
                          await controller.confirmArrivals(plain);
                          if (context.mounted &&
                              controller.lastError == null &&
                              controller.arrived.isEmpty &&
                              controller.disputed.isEmpty) {
                            Navigator.of(context).pop();
                          }
                        },
                  child: Text(
                    asking
                        ? 'Checking today\'s price…'
                        : plain.length == 1
                        ? 'Confirm it'
                        : plain.length == arrived.length
                        ? 'Confirm all'
                        : 'Confirm the ${plain.length} that check out',
                  ),
                ),
              ],
            ),
    );
  }
}

/// What the payee is told about a record §14.7 holds as disputed.
const String disputedConcern =
    'Another payer says this same transaction was theirs. A transaction does '
    'not say who sent it, so check with both before confirming either.';

/// What the payee must be told about [arrival] before confirming it, in the
/// order they matter; empty when its figures hold up.
///
/// [live] is the current price of a ZEC in the payment's currency, or null
/// when none could be read, which is not by itself a reason to hold a
/// payment back.
List<String> arrivalConcerns({
  required splitz.Arrival arrival,
  required BillView? view,
  required int? live,
}) => paymentConcerns(payment: arrival.payment, view: view, live: live);

/// [arrivalConcerns] for a ZEC or swap record, wherever the payee is asked
/// to confirm it.
List<String> paymentConcerns({
  required protocol.PaymentRecord payment,
  required BillView? view,
  required int? live,
}) {
  final out = <String>[];
  final p = payment;
  final bill = view?.bill;
  final rate = bill?.rate;
  final zatoshi = p.zatoshi;
  String who(String id) =>
      bill?.displayNameOf(id, creatorId: view?.creatorId) ?? id;
  if (rate == null || rate.currency != p.currency) {
    out.add(
      'This bill has no price in ${p.currency}, so nothing says what this '
      'ZEC is worth.',
    );
  } else if (zatoshi != null) {
    // §2.2 bounds an amount, not its product with a rate: a peer can state
    // both so that the worth is past 2^63-1, which the conversion refuses.
    int? worth;
    try {
      worth = protocol.zatoshiToFiat(zatoshi, rate);
    } on protocol.SplitError {
      out.add(
        '${formatZec(zatoshi)} at the bill\'s price of '
        '${formatAmount(rate.minorUnitsPerZec, p.currency)} a ZEC is worth '
        'more than this app can count. Check it by hand.',
      );
    }
    // Short by more than 5%: the whole-percent line the payer's review draws
    // for a rate, drawn here for what the ZEC is worth.
    if (worth != null &&
        BigInt.from(worth) * BigInt.from(100) <
            BigInt.from(p.amount) * BigInt.from(95)) {
      out.add(
        '${formatZec(zatoshi)} is worth '
        '${formatAmount(worth, p.currency)} at the bill\'s price of '
        '${formatAmount(rate.minorUnitsPerZec, p.currency)} a ZEC, not the '
        '${formatAmount(p.amount, p.currency)} this settles.',
      );
    }
  }
  if (view?.rateSetBy != null && view!.rateSetBy == p.from) {
    out.add('${who(p.from)} set this bill\'s price and is the one paying.');
  }
  final paidAt = p.paidAtRate;
  if (paidAt != null &&
      rate != null &&
      paidAt.minorUnitsPerZec != rate.minorUnitsPerZec) {
    out.add(
      'Priced at ${formatAmount(paidAt.minorUnitsPerZec, p.currency)} a ZEC, '
      'where the bill says ${formatAmount(rate.minorUnitsPerZec, p.currency)}.',
    );
  }
  final priced = paidAt?.minorUnitsPerZec ?? rate?.minorUnitsPerZec;
  if (priced != null && live != null && live > 0) {
    final off =
        ((BigInt.from(priced) - BigInt.from(live)) *
                BigInt.from(100) ~/
                BigInt.from(live))
            .toInt();
    if (off.abs() >= 5) {
      out.add(
        'That price is ${off.abs()}% ${off > 0 ? 'above' : 'below'} today\'s '
        '${formatAmount(live, p.currency)} a ZEC, so it '
        '${off > 0 ? 'settles more of the debt than the ZEC is worth' : 'asks for more ZEC than the debt'}.',
      );
    }
  }
  return out;
}

class _Arrival extends StatelessWidget {
  const _Arrival({
    required this.arrival,
    required this.concerns,
    this.confirmable = true,
  });

  final splitz.Arrival arrival;
  final List<String> concerns;
  final bool confirmable;

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
    final error = Theme.of(context).colorScheme.error;
    final key = '${arrival.billId}_${payment.id}';
    final settles = formatAmount(payment.amount, payment.currency);
    return RowCard(
      key: Key('splits_arrival_$key'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CardLine(
            title: '$from · ${view?.bill.name ?? 'Bill'}',
            subtitle: Text(
              [
                if (zatoshi != null) formatZec(zatoshi),
                if (rate != null)
                  'at ${formatAmount(rate.minorUnitsPerZec, rate.currency)}/ZEC',
                'tx ${arrival.txid.substring(0, 8)}…',
              ].join(' · '),
            ),
            trailing: settles,
          ),
          for (final c in concerns)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(c, style: TextStyle(color: error)),
            ),
          if (concerns.isNotEmpty && confirmable)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: Key('splits_arrival_confirm_anyway_$key'),
                onPressed: controller.busy
                    ? null
                    : () async {
                        final sure = await showDialog<bool>(
                          context: context,
                          builder: (dialog) => AlertDialog(
                            title: Text('Confirm $settles from $from?'),
                            content: Text(
                              '${concerns.join('\n\n')}\n\nThis settles '
                              '$settles of what $from owes you.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(dialog).pop(false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                key: const Key(
                                  'splits_arrival_confirm_anyway_sure',
                                ),
                                onPressed: () => Navigator.of(dialog).pop(true),
                                child: const Text('Confirm'),
                              ),
                            ],
                          ),
                        );
                        if (sure == true) {
                          await controller.confirmArrivals([arrival]);
                        }
                      },
                child: const Text('Confirm anyway'),
              ),
            ),
        ],
      ),
    );
  }
}
