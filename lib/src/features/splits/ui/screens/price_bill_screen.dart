/// Putting a price on a bill, which is what makes it settleable.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/splits_controller.dart';
import '../view/naming.dart';
import 'package:splitz_host/splitz_host.dart' show BillNaming, parseAmountIn;

import 'add_expense_screen.dart' show figureRefusal;
import '../view/chrome.dart';
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

class _PriceBillScreenState extends State<PriceBillScreen> with SplitsActions {
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

  /// Whether a price is being written. Set before the first await, so a
  /// second tap in the same frame writes nothing and closes nothing.
  bool _applying = false;

  Future<void> _apply(String currency) async {
    if (_applying) return;
    if (!_form.currentState!.validate()) return;
    _applying = true;
    try {
      await _write(currency);
    } finally {
      _applying = false;
    }
  }

  Future<void> _write(String currency) async {
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);
    final asked = parseAmountIn(_price.text, currency)!;
    final set = await act(
      () => controller.setRate(
        billId: widget.billId,
        currency: currency,
        minorUnitsPerZec: asked,
        // Where the figure came from, so a reader of the bill is not left to
        // guess whether somebody typed it.
        source: asked == _suggested ? 'feed' : 'typed',
      ),
    );
    if (!mounted || !set) return;
    // Written is not applied: §10.1 takes the organiser's latest `setRate`
    // over anybody else's, and otherwise the latest by `at`, so one dated
    // ahead of this device's clock outranks this one. Closing the screen would
    // say the bill was repriced when it was not.
    final view = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull;
    final carried = view?.bill.rate;
    if (carried != null && carried.minorUnitsPerZec == asked) {
      navigator.pop();
      return;
    }
    final by = view?.rateSetBy;
    final organisers = view != null && by != null && by == view.creatorId;
    final mine = organisers && by == controller.me;
    setState(() {
      _notApplied = mine
          ? 'The bill still carries your earlier price, which is dated later '
                'than this one. Withdraw it below, then set the price again.'
          : organisers
          ? 'The bill still carries the organiser\'s price, which stands over '
                'anybody else\'s. Ask the organiser to change it.'
          : 'The bill still carries the earlier price: '
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
        content: const Text('The earlier price, if any, applies again.'),
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
    await act(() => controller.withdraw(billId: widget.billId, entryId: entry));
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
      bottomNavigationBar: BottomActions(
        children: [
          FilledButton(
            key: const Key('splits_price_apply'),
            onPressed: controller.busy ? null : () => _apply(currency),
            child: Text(
              existing == null
                  ? 'Put this price on the bill'
                  : 'Reprice the bill',
            ),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Price of 1 ZEC in $currency.'),
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
                    ? null
                    : 'The feed says '
                          '${formatAmount(_suggested!, currency)}.',
                helperMaxLines: fieldNoteLines,
                errorMaxLines: fieldNoteLines,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              validator: (v) {
                final units = parseAmountIn(v ?? '', currency);
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
            if (failure case final failed?)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  failed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            // §10.8: the creator may withdraw any `setRate`, which is what
            // takes one dated far ahead off the bill: somebody else's, or
            // their own when it outranked the price they just set.
            if (existing != null &&
                view.creatorId == controller.me &&
                (view.rateSetBy != controller.me || _notApplied != null) &&
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
              'Debts stay in $currency.',
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
