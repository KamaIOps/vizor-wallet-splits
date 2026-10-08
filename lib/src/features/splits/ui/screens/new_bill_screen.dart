/// Opening a bill.
library;

import 'package:flutter/material.dart';

import 'package:splitz_host/splitz_host.dart' show currencyExponent;
import '../view/chrome.dart';
import 'bill_screen.dart';
import 'splits_scope.dart';

/// Names a bill, its currency, and the person opening it.
class NewBillScreen extends StatefulWidget {
  const NewBillScreen({super.key});

  @override
  State<NewBillScreen> createState() => _NewBillScreenState();
}

class _NewBillScreenState extends State<NewBillScreen> with SplitsActions {
  final _name = TextEditingController();
  // USD by default: it is the currency the wallet's own price feed quotes, so
  // a bill in it is priced automatically when somebody settles.
  final _currency = TextEditingController(text: 'USD');
  final _displayName = TextEditingController();
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _currency.dispose();
    _displayName.dispose();
    super.dispose();
  }

  /// Whether a bill is being opened. Set before the first await, so a
  /// second tap in the same frame opens nothing.
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    if (!_form.currentState!.validate()) return;
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);

    setState(() => _opening = true);
    String? id;
    try {
      await act(() async {
        id = await controller.createBill(
          name: _name.text.trim(),
          currency: _currency.text.trim().toUpperCase(),
          displayName: _displayName.text.trim().isEmpty
              ? null
              : _displayName.text.trim(),
        );
      });
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    if (!mounted) return;
    // Null leaves the error in [failure], where it is shown.
    if (id case final billId?) {
      navigator.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => BillScreen(billId: billId)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('New bill')),
      bottomNavigationBar: BottomActions(
        children: [
          FilledButton(
            key: const Key('splits_new_bill_open'),
            onPressed: controller.busy || _opening ? null : _open,
            child: Text(
              controller.busy || _opening ? 'Opening…' : 'Open the bill',
            ),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'What is it for',
                hintText: 'Dinner',
                errorMaxLines: fieldNoteLines,
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Give the bill a name' : null,
            ),
            const SizedBox(height: 8),
            // Read inside the field as one line, "Currency USD", in the
            // label's light style like the rows around it.
            TextFormField(
              controller: _currency,
              style: Theme.of(context).inputDecorationTheme.labelStyle,
              decoration: InputDecoration(
                // Shown whether or not the field holds a code, and found by
                // its text, as the label it replaces was.
                prefixIcon: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                  child: Text(
                    'Currency',
                    style: Theme.of(context).inputDecorationTheme.labelStyle,
                  ),
                ),
                prefixIconConstraints: const BoxConstraints(),
                errorMaxLines: fieldNoteLines,
              ),
              textCapitalization: TextCapitalization.characters,
              validator: (v) {
                final code = (v ?? '').trim().toUpperCase();
                // §2: three letters. Checked here so the refusal arrives while
                // the field is still in front of the person who typed it.
                if (code.length != 3 || !RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
                  return 'Three letters, as in EUR';
                }
                // §2.1: a code with no minor unit in the ISO 4217 register
                // has no scale a typed figure could be read at.
                if (currencyExponent(code) == null) {
                  return '$code is not a currency this wallet can split';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _displayName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Your name on this bill',
                hintText: 'optional',
              ),
            ),
            if (failure case final failed?)
              Padding(
                padding: const EdgeInsets.only(top: 16),
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
