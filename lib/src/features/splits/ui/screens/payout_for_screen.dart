/// How somebody added by name gets paid, set by whoever pays them (§9.1).
///
/// A person added by name has no device on the bill to say this themselves,
/// so a payer who knows it writes it for them: a Zcash address, or USDC on a
/// chain they name, swapped from ZEC when the debt is paid.
library;

import 'package:flutter/material.dart';

import 'package:splitz_core/splitz_core.dart' as splitz;

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import 'splits_scope.dart';
import 'text_entry_screen.dart' show zcashAddressIn;
import 'usdc_chains.dart';

enum _Way { zec, usdc, cash }

class PayoutForScreen extends StatefulWidget {
  const PayoutForScreen({
    super.key,
    required this.billId,
    required this.id,
    required this.name,
  });

  final String billId;
  final String id;
  final String name;

  @override
  State<PayoutForScreen> createState() => _PayoutForScreenState();
}

class _PayoutForScreenState extends State<PayoutForScreen> {
  final _zec = TextEditingController();
  final _usdcAddress = TextEditingController();
  final _scroll = ScrollController();

  _Way _way = _Way.zec;
  String? _chain;

  /// Why the chains could not be listed; USDC cannot be chosen then.
  String? _chainsUnavailable;

  String? _unsaved;
  bool _saving = false;
  bool _loaded = false;

  @override
  void dispose() {
    _zec.dispose();
    _usdcAddress.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Opens on what the bill already says about them, so saving never
  /// replaces it with a default.
  void _loadOnce(SplitsController controller) {
    if (_loaded) return;
    _loaded = true;
    final who = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull
        ?.bill
        .participant(widget.id);
    if (who == null) return;
    _zec.text = who.payTo ?? '';
    final first = who.payouts.isEmpty ? null : who.payouts.first;
    if (first != null &&
        first.type == 'swap' &&
        (first.asset ?? '').toUpperCase() == usdc) {
      _way = _Way.usdc;
      _chain = first.chain;
      _usdcAddress.text = first.address ?? '';
    }
  }

  Future<void> _scanInto(
    TextEditingController field, {
    required bool zec,
  }) async {
    final scan = SplitsScope.scannerOf(context);
    if (scan == null) return;
    final scanned = await scan(context);
    if (scanned == null || !mounted) return;
    setState(() => field.text = zec ? zcashAddressIn(scanned) : scanned.trim());
  }

  Future<void> _save() async {
    final chain = _chain;
    final address = (_way == _Way.zec ? _zec : _usdcAddress).text.trim();
    final missing = _way == _Way.cash
        ? null
        : _way == _Way.usdc && chain == null
        ? 'Pick the chain they want USDC on.'
        : address.isEmpty
        ? 'Nobody can be paid without an address.'
        : _way == _Way.usdc
        ? usdcAddressIssue(chain!, address)
        : null;
    if (missing != null) {
      setState(() => _unsaved = missing);
      return;
    }
    setState(() {
      _unsaved = null;
      _saving = true;
    });
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);
    if (_way == _Way.zec) {
      await controller.setAddressFor(
        billId: widget.billId,
        id: widget.id,
        address: zcashAddressIn(address),
      );
    } else {
      await controller.setPayoutFor(
        billId: widget.billId,
        id: widget.id,
        payout: _way == _Way.cash
            ? const splitz.Payout(type: 'cash')
            : splitz.Payout(
                type: 'swap',
                asset: usdc,
                chain: chain!,
                address: address,
              ),
      );
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (controller.lastError == null) navigator.pop(true);
  }

  /// An address field, with Scan QR inside it where the wallet has a camera
  /// to lend.
  Widget _addressField({
    required String key,
    required TextEditingController field,
    required String hint,
    required bool zec,
  }) {
    final scans = SplitsScope.scannerOf(context) != null;
    return TextField(
      key: Key(key),
      controller: field,
      enabled: !_saving,
      autocorrect: false,
      decoration: InputDecoration(
        hintText: hint,
        suffixIcon: scans
            ? IconButton(
                key: Key('${key}_scan'),
                tooltip: 'Scan QR',
                icon: const Icon(Icons.qr_code_scanner),
                onPressed: _saving ? null : () => _scanInto(field, zec: zec),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    _loadOnce(controller);
    final name = widget.name;
    final chain = _chain;

    return Scaffold(
      appBar: AppBar(title: Text('How $name gets paid')),
      bottomNavigationBar: BottomActions(
        children: [
          if (_unsaved ?? controller.lastError case final said?)
            Text(
              said,
              key: const Key('splits_payout_for_unsaved'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          FilledButton(
            key: const Key('splits_address_save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.all(16),
          children: [
            RadioGroup<_Way>(
              groupValue: _way,
              onChanged: (value) {
                if (_saving || value == null) return;
                setState(() {
                  _way = value;
                  _unsaved = null;
                });
              },
              child: Column(
                children: [
                  RadioListTile<_Way>(
                    key: const Key('splits_payout_for_zec'),
                    value: _Way.zec,
                    title: const Text('Zcash'),
                    subtitle: Text('Straight to $name’s Zcash address'),
                  ),
                  RadioListTile<_Way>(
                    key: const Key('splits_payout_for_usdc'),
                    value: _Way.usdc,
                    enabled: _chainsUnavailable == null,
                    title: const Text('USDC'),
                    subtitle: Text(
                      _chainsUnavailable == null
                          ? 'Swapped from ZEC with NEAR Intents'
                          : 'Couldn’t load where USDC can arrive',
                    ),
                  ),
                  RadioListTile<_Way>(
                    key: const Key('splits_payout_for_cash'),
                    value: _Way.cash,
                    title: const Text('Cash'),
                    subtitle: const Text(
                      'In person, recorded when it’s handed over',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (_way == _Way.zec)
              _addressField(
                key: 'splits_address_field',
                field: _zec,
                hint: 'Zcash address',
                zec: true,
              )
            else if (_way == _Way.usdc) ...[
              UsdcChainPicker(
                picked: chain,
                enabled: !_saving,
                onPicked: (c) => setState(() {
                  _chain = c;
                  _unsaved = null;
                }),
                onUnavailable: (why) => setState(() {
                  _chainsUnavailable = why;
                  _way = _Way.zec;
                }),
                // Under the chain just picked, not below every other one.
                belowPicked: chain == null
                    ? null
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _addressField(
                            key: 'splits_payout_for_usdc_address',
                            field: _usdcAddress,
                            hint: '${usdcChainName(chain)} address',
                            zec: false,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '$name’s USDC will be delivered to this address.',
                          ),
                        ],
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
