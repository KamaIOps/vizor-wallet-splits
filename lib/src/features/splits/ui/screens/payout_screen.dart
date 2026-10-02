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

import '../view/chrome.dart';
import 'splits_scope.dart';
import 'usdc_chains.dart';

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

class _PayoutScreenState extends State<PayoutScreen> with SplitsActions {
  final _form = GlobalKey<FormState>();
  final _asset = TextEditingController();
  final _chain = TextEditingController();
  final _address = TextEditingController();

  /// The list's scroll, so its scrollbar can stay visible: with every chain
  /// listed, Save's fields run below the fold.
  final _scroll = ScrollController();

  PayoutChoice _choice = PayoutChoice.zec;

  /// Ways a payer may use instead of [_choice], after it and in this order:
  /// the wallet's own Zcash address, then cash (§9.1, §14.8).
  bool _alsoZec = false;
  bool _alsoCash = false;

  /// Later payouts this screen does not edit — a swap declared after the
  /// first — written back as they were so saving never drops them.
  List<splitz.Payout> _kept = const [];

  bool _loaded = false;
  bool _saving = false;

  /// Why Save did nothing, when the screen can tell before asking anyone.
  String? _unsaved;

  /// Why the chains could not be listed, when they could not.
  String? _chainsUnavailable;

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
    _scroll.dispose();
    super.dispose();
  }

  /// Reads what this device already declared, so the screen opens on the
  /// current answer rather than on a default that would overwrite it.
  void _loadOnce(splitz.Participant? me) {
    if (_loaded || me == null) return;
    _loaded = true;
    final first = me.payouts.isEmpty ? null : me.payouts.first;
    if (first == null) return;
    final later = me.payouts.skip(1);
    _alsoZec = later.any((p) => p.type == 'zec');
    _alsoCash = later.any((p) => p.type == 'cash');
    _kept = [
      for (final p in later)
        if (p.type != 'zec' && p.type != 'cash') p,
    ];
    switch (first.type) {
      case 'swap':
        _choice = PayoutChoice.swap;
        _asset.text = first.asset ?? '';
        _chain.text = first.chain ?? '';
        _address.text = first.address ?? '';
        if ((first.asset ?? '').toUpperCase() == usdc) {
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

  /// The list this device declares, most preferred first.
  ///
  /// Zcash alone is an empty list: `joinBill` writes the wallet's address as
  /// `payTo`, and that stays the single source. With anything after it, Zcash
  /// is written out with that same address, since a list's first entry is
  /// what decides the lane.
  List<splitz.Payout> _declared(String? walletAddress) {
    final zec = walletAddress == null
        ? null
        : splitz.Payout(type: 'zec', address: walletAddress);
    final backups = [
      if (_choice != PayoutChoice.zec && _alsoZec && zec != null) zec,
      if (_choice != PayoutChoice.cash && _alsoCash)
        const splitz.Payout(type: 'cash'),
      ..._kept,
    ];
    final first = _first();
    if (first.isEmpty && backups.isEmpty) return const [];
    return [if (first.isEmpty && zec != null) zec else ...first, ...backups];
  }

  List<splitz.Payout> _first() => switch (_choice) {
    PayoutChoice.zec => const <splitz.Payout>[],
    PayoutChoice.swap => [
      splitz.Payout(
        type: 'swap',
        asset: _typed ? _asset.text.trim() : usdc,
        chain: _typed ? _chain.text.trim() : _pickedChain,
        address: _address.text.trim(),
      ),
    ],
    PayoutChoice.cash => const [splitz.Payout(type: 'cash')],
  };

  Future<void> _save() async {
    // Set before the first await below: a second tap in the same frame
    // reaches this before any rebuild has disabled the button.
    if (_saving) return;
    // Checked here and not only by the form: the form validates the fields
    // its list has built, and with many chains the address is below the
    // fold. Every refusal is said beside Save — a Save that silently stays
    // put reads as broken.
    final missing = _choice != PayoutChoice.swap
        ? null
        : !_typed && _pickedChain == null
        ? 'Pick the chain you want USDC on.'
        : _typed && _asset.text.trim().isEmpty
        ? 'Name the asset.'
        : _typed && _chain.text.trim().isEmpty
        ? 'Name the chain.'
        : _address.text.trim().isEmpty
        ? 'Nobody can be paid without an address.'
        : null;
    final valid = _form.currentState?.validate() ?? false;
    if (missing != null || !valid) {
      setState(() => _unsaved = missing ?? 'Check the fields marked above.');
      return;
    }
    setState(() {
      _unsaved = null;
      _saving = true;
    });
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);
    final saved = await act(
      () => controller.setPayouts(
        billId: widget.billId,
        payouts: _declared(controller.payToAddress),
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) navigator.pop();
  }

  /// Clears a refusal once the field it asked about is typed into.
  void _edited(String _) {
    if (_unsaved != null) setState(() => _unsaved = null);
  }

  /// The asset and chain as free text, for a payout the picker cannot hold.
  List<Widget> _typedFields() => [
    const SizedBox(height: 8),
    TextFormField(
      key: const Key('splits_payout_asset'),
      controller: _asset,
      decoration: const InputDecoration(
        labelText: 'Asset',
        hintText: 'USDC',
        errorMaxLines: fieldNoteLines,
      ),
      textCapitalization: TextCapitalization.characters,
      onChanged: _edited,
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
        helperMaxLines: fieldNoteLines,
        errorMaxLines: fieldNoteLines,
      ),
      onChanged: _edited,
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
          // Beside Save rather than at the end of the list: with many chains
          // the end is below the fold, and a refused Save would look like
          // nothing happened.
          if (_unsaved ?? failure case final said?)
            Text(
              said,
              key: const Key('splits_payout_unsaved'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          FilledButton(
            key: const Key('splits_payout_save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            children: [
              RadioGroup<PayoutChoice>(
                groupValue: _choice,
                onChanged: (value) {
                  if (_saving || value == null) return;
                  setState(() {
                    _choice = value;
                    _unsaved = null;
                  });
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
                  UsdcChainPicker(
                    picked: _pickedChain,
                    enabled: !_saving,
                    onPicked: (chain) => setState(() {
                      _pickedChain = chain;
                      _unsaved = null;
                    }),
                    onUnavailable: (why) => setState(() {
                      _typed = true;
                      _chainsUnavailable = why;
                    }),
                  )
                else ...[
                  if (_chainsUnavailable != null)
                    Padding(
                      key: const Key('splits_payout_chains_unavailable'),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Couldn’t load chains. Type the asset and chain.',
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
                        : 'Your USDC address on ${usdcChainName(_pickedChain!)}',
                    errorMaxLines: fieldNoteLines,
                  ),
                  onChanged: _edited,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Nobody can be paid without an address'
                      : !_typed && _pickedChain != null
                      ? usdcAddressIssue(_pickedChain!, v)
                      : null,
                ),
              ],
              if (_choice == PayoutChoice.cash)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('You confirm cash when it arrives.'),
                ),
              // A payer who cannot use the first way — no route to the asset,
              // too far away for cash — may pay by one of these instead.
              const SectionLabel('Also accept, if that doesn’t work'),
              if (_choice != PayoutChoice.zec &&
                  controller.payToAddress != null)
                CheckboxListTile(
                  key: const Key('splits_payout_also_zec'),
                  value: _alsoZec,
                  title: const Text('Zcash'),
                  subtitle: const Text('Straight to your wallet'),
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _alsoZec = v ?? false),
                ),
              if (_choice != PayoutChoice.cash)
                CheckboxListTile(
                  key: const Key('splits_payout_also_cash'),
                  value: _alsoCash,
                  title: const Text('Cash'),
                  subtitle: const Text(
                    'In person — you confirm when it arrives',
                  ),
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _alsoCash = v ?? false),
                ),
              for (final p in _kept)
                ListTile(
                  title: Text('${p.asset} on ${p.chain}'),
                  subtitle: const Text('Kept from before'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
