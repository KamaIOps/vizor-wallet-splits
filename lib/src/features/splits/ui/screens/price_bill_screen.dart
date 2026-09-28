/// Putting a price on a bill, which is what makes it settleable.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/splits_controller.dart';
import '../view/naming.dart';
import 'add_expense_screen.dart' show figureRefusal, parseMinorUnits;
import 'splits_scope.dart';

/// Snapshots what one ZEC costs onto the bill (§7).
///
/// Snapshotted rather than looked up per device, and that is the whole point:
/// the live price ticks, and two devices pricing the same debt a second apart
/// would owe different amounts. Once it is on the bill, every device reads the
/// same figure.
class PriceBillScreen extends StatefulWidget {
  const PriceBillScreen({super.key, required this.billId});

  final String billId;

  @override
  State<PriceBillScreen> createState() => _PriceBillScreenState();
}

class _PriceBillScreenState extends State<PriceBillScreen> {
  final _price = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _asked = false;
  int? _suggested;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _ask(String currency) async {
    _asked = true;
    final controller = SplitsScope.read(context);
    final quoted = await controller.quoteZec(currency);
    if (!mounted || quoted == null) return;
    setState(() {
      _suggested = quoted;
      if (_price.text.isEmpty) {
        _price.text = formatAmount(quoted, currency, withCurrency: false);
      }
    });
  }

  /// Why the last price written is not the one the bill carries, or null.
  String? _notApplied;

  Future<void> _apply(String currency) async {
    if (!_form.currentState!.validate()) return;
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);
    final asked = parseMinorUnits(_price.text, currency: currency)!;
    await controller.setRate(
      billId: widget.billId,
      currency: currency,
      minorUnitsPerZec: asked,
      // Where the figure came from, so a reader of the bill is not left to
      // guess whether somebody typed it.
      source: asked == _suggested ? 'feed' : 'typed',
    );
    if (!mounted) return;
    if (controller.lastError != null) return;
    // Written is not applied: §10.1 takes the latest `setRate` by `at`, so one
    // dated ahead of this device's clock outranks this one. Closing the screen
    // would say the bill was repriced when it was not.
    final view = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull;
    final carried = view?.bill.rate;
    if (carried != null && carried.minorUnitsPerZec == asked) {
      navigator.pop();
      return;
    }
    final by = view?.rateSetBy;
    setState(() {
      _notApplied =
          'The bill still carries the earlier price: '
          '${by == null || view == null ? 'another' : 'the one ${view.bill.displayNameOf(by, creatorId: view.creatorId)} set'} '
          'is dated later than yours. '
          '${view?.creatorId == controller.me ? 'As the organiser you can withdraw it below.' : 'Ask the organiser to withdraw it.'}';
    });
  }

  Future<void> _withdrawRate(BillView view) async {
    final controller = SplitsScope.read(context);
    final entry = view.rateEntry;
    if (entry == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Withdraw this price?'),
        content: const Text(
          'It comes off the bill, and the price before it — or none — applies '
          'on every device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const Key('splits_price_withdraw_confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Withdraw'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await controller.withdraw(billId: widget.billId, entryId: entry);
    if (mounted) setState(() => _notApplied = null);
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull;
    if (view == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Price this bill')),
        body: const Center(
          child: Text('This device no longer holds this bill.'),
        ),
      );
    }
    final currency = view.bill.currency;
    if (!_asked) _ask(currency);
    final existing = view.bill.rate;

    return Scaffold(
      appBar: AppBar(title: const Text('Price this bill')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'What one ZEC costs in $currency. It is written onto the bill, '
              'so every device settles at the same figure rather than at '
              'whatever the price happens to be when they look.',
            ),
            const SizedBox(height: 16),
            if (existing != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Priced now at '
                  '${formatAmount(existing.minorUnitsPerZec, currency)} per ZEC'
                  '${existing.source == null ? '' : ' (${existing.source})'}.',
                ),
              ),
            TextFormField(
              controller: _price,
              decoration: InputDecoration(
                labelText: 'One ZEC costs',
                suffixText: currency,
                helperText: _suggested == null
                    ? 'This build has no price feed, so type the figure.'
                    : 'The feed says '
                          '${formatAmount(_suggested!, currency)}.',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              validator: (v) {
                final units = parseMinorUnits(v ?? '', currency: currency);
                // §7 refuses a rate that is not positive, and a bill priced at
                // zero would make every debt cost nothing.
                if (units == null) return figureRefusal(currency);
                if (units <= 0) return 'A price is more than nothing';
                return null;
              },
            ),
            const SizedBox(height: 24),
            if (_notApplied != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _notApplied!,
                  key: const Key('splits_price_not_applied'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (controller.lastError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  controller.lastError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton(
              onPressed: controller.busy ? null : () => _apply(currency),
              child: Text(
                existing == null
                    ? 'Put this price on the bill'
                    : 'Reprice the bill',
              ),
            ),
            // §10.8: the creator may withdraw any `setRate`, which is what
            // takes one dated far ahead off the bill.
            if (existing != null &&
                view.creatorId == controller.me &&
                view.rateSetBy != controller.me &&
                view.rateEntry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('splits_price_withdraw'),
                onPressed: controller.busy ? null : () => _withdrawRate(view),
                child: const Text('Withdraw the current price'),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Repricing does not change what anybody owes. A debt stays in '
              '$currency; the price only decides how much ZEC settles it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
