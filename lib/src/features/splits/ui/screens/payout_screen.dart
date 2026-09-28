/// How you want to be paid (SPEC.md §9.1).
///
/// A bill settles in whichever of three ways the recipient asked for: a
/// shielded Zcash output, a swap into another asset on another chain, or cash.
/// Until somebody declares one, they are paid to their wallet address and
/// nothing else is reachable — so this screen is what makes the other two
/// lanes exist at all.
///
/// **The order is the preference.** The first entry decides the lane, and a
/// screen that quietly fell through to the second because the first was
/// inconvenient would pay somebody somewhere they ranked lower.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/splitz_core.dart' as splitz;

import 'splits_scope.dart';

/// The three ways a person can ask to be paid.
enum PayoutChoice {
  /// A shielded Zcash output. Several recipients share one transaction.
  zec,

  /// Swapped into another asset on another chain. One swap per recipient.
  swap,

  /// Handed over outside the app entirely.
  cash,
}

extension PayoutChoiceText on PayoutChoice {
  String get label => switch (this) {
    PayoutChoice.zec => 'Zcash',
    PayoutChoice.swap => 'Another asset',
    PayoutChoice.cash => 'Cash',
  };

  String get detail => switch (this) {
    PayoutChoice.zec =>
      'Paid straight to your wallet. Several people can be paid in one '
          'transaction.',
    PayoutChoice.swap =>
      'Your ZEC is swapped and the other asset is sent to you. One swap '
          'each, so this is not batched with anyone else.',
    PayoutChoice.cash =>
      'Settled between you, outside this app. Nothing verifies it, so '
          'you have to say when it arrives.',
  };
}

class PayoutScreen extends StatefulWidget {
  const PayoutScreen({super.key, required this.billId});

  final String billId;

  @override
  State<PayoutScreen> createState() => _PayoutScreenState();
}

class _PayoutScreenState extends State<PayoutScreen> {
  final _form = GlobalKey<FormState>();
  final _asset = TextEditingController();
  final _chain = TextEditingController();
  final _address = TextEditingController();

  PayoutChoice _choice = PayoutChoice.zec;
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    _asset.dispose();
    _chain.dispose();
    _address.dispose();
    super.dispose();
  }

  /// Reads what this device already declared, so the screen opens on the
  /// current answer rather than on a default that would overwrite it.
  void _loadOnce(splitz.Participant? me) {
    if (_loaded || me == null) return;
    _loaded = true;
    final first = me.payouts.isEmpty ? null : me.payouts.first;
    if (first == null) return;
    switch (first.type) {
      case 'swap':
        _choice = PayoutChoice.swap;
        _asset.text = first.asset ?? '';
        _chain.text = first.chain ?? '';
        _address.text = first.address ?? '';
      case 'cash':
        _choice = PayoutChoice.cash;
      case 'zec':
        _choice = PayoutChoice.zec;
    }
  }

  List<splitz.Payout> _declared() => switch (_choice) {
    // A `zec` payout with no address is nobody to pay, so the wallet's
    // own address is what stands behind this choice. `joinBill` writes it
    // as `payTo`; declaring the list empty keeps that the single source.
    PayoutChoice.zec => const <splitz.Payout>[],
    PayoutChoice.swap => [
      splitz.Payout(
        type: 'swap',
        asset: _asset.text.trim(),
        chain: _chain.text.trim(),
        address: _address.text.trim(),
      ),
    ],
    PayoutChoice.cash => const [splitz.Payout(type: 'cash')],
  };

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);
    await controller.setPayouts(billId: widget.billId, payouts: _declared());
    if (!mounted) return;
    setState(() => _saving = false);
    if (controller.lastError == null) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull;
    _loadOnce(view?.bill.participant(controller.me));

    return Scaffold(
      appBar: AppBar(title: const Text('How you get paid')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            RadioGroup<PayoutChoice>(
              groupValue: _choice,
              onChanged: (value) {
                if (_saving || value == null) return;
                setState(() => _choice = value);
              },
              child: Column(
                children: [
                  for (final choice in PayoutChoice.values)
                    RadioListTile<PayoutChoice>(
                      key: Key('splits_payout_${choice.name}'),
                      value: choice,
                      title: Text(choice.label),
                      subtitle: Text(choice.detail),
                      isThreeLine: true,
                    ),
                ],
              ),
            ),
            if (_choice == PayoutChoice.swap) ...[
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('splits_payout_asset'),
                controller: _asset,
                decoration: const InputDecoration(
                  labelText: 'Asset',
                  hintText: 'USDC',
                ),
                textCapitalization: TextCapitalization.characters,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Name the asset' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('splits_payout_chain'),
                controller: _chain,
                decoration: const InputDecoration(
                  labelText: 'Chain',
                  hintText: 'base',
                  // One symbol exists on many chains, and the wrong chain
                  // delivers the right token somewhere unreachable.
                  helperText: 'The network it should arrive on',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Name the chain' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('splits_payout_address'),
                controller: _address,
                decoration: const InputDecoration(labelText: 'Your address'),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Nobody can be paid without an address'
                    : null,
              ),
            ],
            if (_choice == PayoutChoice.cash)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Cash is not verified by anything. Anyone on the bill can '
                  'say they paid you, so it only settles when you confirm it '
                  'arrived.',
                ),
              ),
            if (controller.lastError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  controller.lastError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('splits_payout_save'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
