/// Saying a debt was settled some way other than a batched Zcash send.
///
/// A payment record is a **claim**, not a settlement (§10.5): the balance does
/// not move until the payee says the money arrived. That is why this screen
/// never says "paid" — it says what was recorded, and who has to confirm it.
///
/// Two methods reach this screen, because they are the two §8.5 cannot put in
/// a payment request:
///
///   * `cash`, which nothing verifies — anyone on the bill can write one;
///   * `swap`, which is verifiable only in half. What left the wallet is ZEC
///     and is recorded; what arrived is another asset on another chain, which
///     this bill cannot see.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../view/chrome.dart';
import '../view/naming.dart';
import 'package:splitz_host/splitz_host.dart' show BillNaming, parseAmountIn;

import 'add_expense_screen.dart' show figureRefusal;
import 'splits_scope.dart';

/// Which of §9.2's two off-request methods is being recorded.
enum RecordMethod { cash, swap }

extension RecordMethodText on RecordMethod {
  String get label => this == RecordMethod.cash
      ? 'Cash or offline'
      : 'Swapped to another asset';

  /// What a person is told they are asserting.
  ///
  /// Neither sentence claims the debt is settled, because neither method
  /// settles one: §10.5 gives that to the payee alone.
  String get caveat => switch (this) {
    RecordMethod.cash => 'Counts once they confirm it.',
    RecordMethod.swap => 'Counts once they confirm it arrived.',
  };
}

class RecordPaymentScreen extends StatefulWidget {
  const RecordPaymentScreen({
    super.key,
    required this.billId,
    required this.to,
    this.suggestedMinorUnits,
  });

  final String billId;

  /// Who is being paid. Never this device: §9.2 refuses a self-payment,
  /// which pads a settlement history rather than moving a balance.
  final String to;

  /// What the plan says is owed, so the common case is one tap.
  final int? suggestedMinorUnits;

  @override
  State<RecordPaymentScreen> createState() => _RecordPaymentScreenState();
}

class _RecordPaymentScreenState extends State<RecordPaymentScreen>
    with SplitsActions {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _note = TextEditingController();

  RecordMethod _method = RecordMethod.cash;
  bool _saving = false;
  bool _filled = false;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _note.dispose();
    super.dispose();
  }

  void _fillOnce(String currency) {
    if (_filled) return;
    _filled = true;
    final owed = widget.suggestedMinorUnits;
    if (owed != null && owed > 0) {
      _amount.text = formatAmount(owed, currency, withCurrency: false);
    }
  }

  Future<void> _save(String currency) async {
    // Set before the first await below: a second tap in the same frame
    // reaches this before any rebuild has disabled the button.
    if (_saving) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    final amount = parseAmountIn(_amount.text, currency);
    if (amount == null || amount <= 0) return;

    setState(() => _saving = true);
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();

    final saved = await act(() async {
      if (_method == RecordMethod.cash) {
        await controller.recordCash(
          billId: widget.billId,
          to: widget.to,
          amountMinorUnits: amount,
          note: note,
        );
      } else {
        await controller.recordSwap(
          billId: widget.billId,
          reference: _reference.text.trim(),
          to: widget.to,
          amountMinorUnits: amount,
          note: note,
        );
      }
    });

    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull;
    if (view == null) {
      return const Scaffold(body: Center(child: Text('This bill is gone')));
    }
    final currency = view.bill.currency;
    _fillOnce(currency);
    final who = view.bill.displayNameOf(widget.to, creatorId: view.creatorId);

    return Scaffold(
      appBar: AppBar(title: const Text('Record a payment')),
      bottomNavigationBar: BottomActions(
        children: [
          FilledButton(
            key: const Key('splits_record_save'),
            onPressed: _saving ? null : () => _save(currency),
            child: Text(_saving ? 'Recording…' : 'Record payment'),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // In the body, where it wraps rather than being cut off: the
            // suffix that tells two people of one name apart is the part an
            // app bar drops first.
            Text(
              'You → $who',
              key: const Key('splits_record_to'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('splits_record_amount'),
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(
                hintText: 'Amount in $currency',
                suffixText: currency,
                errorMaxLines: fieldNoteLines,
              ),
              validator: (v) {
                final parsed = parseAmountIn(v ?? '', currency);
                if (parsed == null) return figureRefusal(currency);
                // A payment of nothing is not a payment, and §9.2 refuses a
                // negative one.
                if (parsed <= 0) return 'More than nothing';
                return null;
              },
            ),
            const SectionLabel('How did you pay?'),
            for (final method in RecordMethod.values)
              OptionPill(
                key: Key('splits_record_${method.name}'),
                label: method.label,
                selected: _method == method,
                onTap: _saving ? null : () => setState(() => _method = method),
              ),
            if (_method == RecordMethod.swap) ...[
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('splits_record_reference'),
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'Swap reference',
                  // Naming what it is not, because a hex string that looks
                  // like a txid is exactly what somebody would paste.
                  helperText:
                      "The provider's id for the swap, or the "
                      'transaction on the other chain — not a Zcash txid',
                  helperMaxLines: fieldNoteLines,
                  errorMaxLines: fieldNoteLines,
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'A swap nobody can look up is a swap nobody can check'
                    : null,
              ),
            ],
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('splits_record_note'),
              controller: _note,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Note (optional)'),
            ),
            const SizedBox(height: 16),
            NoticeCard(message: _method.caveat),
            if (failure case final failed?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  failed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
