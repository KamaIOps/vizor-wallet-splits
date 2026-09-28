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
import 'package:splitz_host/splitz_host.dart' show TradableAsset;
import 'package:zcash_wallet/src/features/swap/domain/swap_asset.dart';

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import 'splits_scope.dart';

/// The three ways a person can ask to be paid.
enum PayoutChoice {
  /// A shielded Zcash output. Several recipients share one transaction.
  zec,

  /// Swapped into USDC on a chain of the recipient's choosing. One swap per
  /// recipient.
  swap,

  /// Handed over outside the app entirely.
  cash,
}

extension PayoutChoiceText on PayoutChoice {
  String get label => switch (this) {
    PayoutChoice.zec => 'Zcash',
    PayoutChoice.swap => 'USDC',
    PayoutChoice.cash => 'Cash',
  };

  String get detail => switch (this) {
    PayoutChoice.zec => 'Straight to your wallet',
    PayoutChoice.swap => 'Swapped from ZEC with NEAR Intents',
    PayoutChoice.cash => 'In person — you confirm when it arrives',
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

  /// The asset a swap payout asks for. The chain is chosen from where the
  /// provider delivers it; anything else is typed by hand.
  static const _usdc = 'USDC';

  /// The chains USDC can arrive on, once the provider has said; null while
  /// it has not been asked or has not answered.
  List<TradableAsset>? _chains;

  /// Why the chains could not be listed, when they could not.
  String? _chainsUnavailable;

  bool _askedForChains = false;

  /// The chain picked from [_chains], or null while none is.
  String? _pickedChain;

  /// True when the chains could not be listed, or this device already asked
  /// for something other than USDC: the asset and chain are then typed.
  bool _typed = false;

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
        if ((first.asset ?? '').toUpperCase() == _usdc) {
          _pickedChain = first.chain;
        } else {
          _typed = true;
        }
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
        asset: _typed ? _asset.text.trim() : _usdc,
        chain: _typed ? _chain.text.trim() : _pickedChain,
        address: _address.text.trim(),
      ),
    ],
    PayoutChoice.cash => const [splitz.Payout(type: 'cash')],
  };

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_choice == PayoutChoice.swap && !_typed && _pickedChain == null) {
      return;
    }
    setState(() => _saving = true);
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);
    await controller.setPayouts(billId: widget.billId, payouts: _declared());
    if (!mounted) return;
    setState(() => _saving = false);
    if (controller.lastError == null) navigator.pop();
  }

  /// A chain id as a person reads it — `base` is Base, `arb` Arbitrum.
  static String _chainName(String chain) => SwapAsset.live(
    assetId: '',
    symbol: _usdc,
    blockchain: chain,
    decimals: 6,
  ).chainLabel;

  /// Every chain the provider delivers USDC on, one choice each.
  ///
  /// Read from the provider rather than written down here, so a chain it adds
  /// or drops is offered or withdrawn without a release. When it cannot be
  /// read, the asset and chain are typed instead of the lane going dark.
  Widget _chainPicker(SplitsController controller) {
    if (!_askedForChains) {
      _askedForChains = true;
      controller
          .deliverableOn(_usdc)
          .then(
            (listed) {
              if (!mounted) return;
              setState(() {
                _chains = listed;
                if (listed.isEmpty) {
                  _typed = true;
                  _chainsUnavailable = 'the provider listed none';
                }
              });
            },
            onError: (Object e) {
              if (!mounted) return;
              setState(() {
                _typed = true;
                _chainsUnavailable = SplitsController.describe(e);
              });
            },
          );
    }
    final listed = _chains;
    if (listed == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('Asking where USDC can arrive…'),
      );
    }
    final picked = _pickedChain?.toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Which chain should it arrive on?'),
        for (final a in listed)
          OptionPill(
            key: Key('splits_payout_chain_${a.chain.toLowerCase()}'),
            label: 'USDC on ${_chainName(a.chain)}',
            selected: picked == a.chain.toLowerCase(),
            onTap: _saving
                ? null
                : () => setState(() => _pickedChain = a.chain),
          ),
      ],
    );
  }

  /// The asset and chain as free text, for a payout the picker cannot hold.
  List<Widget> _typedFields() => [
    const SizedBox(height: 8),
    TextFormField(
      key: const Key('splits_payout_asset'),
      controller: _asset,
      decoration: const InputDecoration(labelText: 'Asset', hintText: 'USDC'),
      textCapitalization: TextCapitalization.characters,
      validator: (v) =>
          (_typed && (v == null || v.trim().isEmpty)) ? 'Name the asset' : null,
    ),
    const SizedBox(height: 8),
    TextFormField(
      key: const Key('splits_payout_chain'),
      controller: _chain,
      decoration: const InputDecoration(
        labelText: 'Chain',
        hintText: 'base',
        // One symbol exists on many chains, and the wrong chain delivers the
        // right token somewhere unreachable.
        helperText: 'The network it should arrive on',
      ),
      validator: (v) =>
          (_typed && (v == null || v.trim().isEmpty)) ? 'Name the chain' : null,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull;
    _loadOnce(view?.bill.participant(controller.me));

    return Scaffold(
      appBar: AppBar(title: const Text('How you get paid')),
      bottomNavigationBar: BottomActions(
        children: [
          FilledButton(
            key: const Key('splits_payout_save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
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
                    ),
                ],
              ),
            ),
            if (_choice == PayoutChoice.swap) ...[
              if (!_typed)
                _chainPicker(controller)
              else ...[
                if (_chainsUnavailable != null)
                  Padding(
                    key: const Key('splits_payout_chains_unavailable'),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'The chains USDC arrives on could not be listed '
                      '($_chainsUnavailable). Type the asset and chain.',
                    ),
                  ),
                ..._typedFields(),
              ],
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('splits_payout_address'),
                controller: _address,
                decoration: InputDecoration(
                  labelText: _typed || _pickedChain == null
                      ? 'Your address'
                      : 'Your USDC address on ${_chainName(_pickedChain!)}',
                ),
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
          ],
        ),
      ),
    );
  }
}
