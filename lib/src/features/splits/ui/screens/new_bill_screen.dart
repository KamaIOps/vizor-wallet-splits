/// Opening a bill.
library;

import 'package:flutter/material.dart';

import '../view/currency_exponents.dart';
import '../view/chrome.dart';
import 'bill_screen.dart';
import 'splits_scope.dart';

/// Names a bill, its currency, and the person opening it.
class NewBillScreen extends StatefulWidget {
  const NewBillScreen({super.key});

  @override
  State<NewBillScreen> createState() => _NewBillScreenState();
}

class _NewBillScreenState extends State<NewBillScreen> {
  final _name = TextEditingController();
  final _currency = TextEditingController(text: 'EUR');
  final _displayName = TextEditingController();
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _currency.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (!_form.currentState!.validate()) return;
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);

    final id = await controller.createBill(
      name: _name.text.trim(),
      currency: _currency.text.trim().toUpperCase(),
      displayName: _displayName.text.trim().isEmpty
          ? null
          : _displayName.text.trim(),
    );
    if (!mounted) return;
    if (id == null) return; // the error is on the controller, and shown.
    navigator.pushReplacement(
      MaterialPageRoute<void>(builder: (_) => BillScreen(billId: id)),
    );
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
            onPressed: controller.busy ? null : _open,
            child: Text(controller.busy ? 'Opening…' : 'Open the bill'),
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
              decoration: const InputDecoration(
                labelText: 'What is it for',
                hintText: 'Dinner',
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Give the bill a name' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _currency,
              decoration: const InputDecoration(
                labelText: 'Currency',
                helperText:
                    'A bill has exactly one currency, and it cannot '
                    'change once it is open.',
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
              decoration: const InputDecoration(
                labelText: 'Your name on this bill',
                hintText: 'optional',
              ),
            ),
            if (controller.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
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
