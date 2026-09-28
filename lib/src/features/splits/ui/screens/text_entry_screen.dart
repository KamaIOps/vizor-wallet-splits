/// One line of text, asked for on a page of its own.
library;

import 'package:flutter/material.dart';

import '../view/chrome.dart';
import 'splits_scope.dart';

/// Asks for one line of text and pops with it, or with null on back.
///
/// A page on the feature's own navigator rather than a dialog: it sits under
/// the [SplitsScope], so the wallet's camera is in reach, and the keyboard
/// has the whole screen to rise over.
class TextEntryScreen extends StatefulWidget {
  const TextEntryScreen({
    super.key,
    required this.title,
    required this.hint,
    required this.action,
    this.fieldKey,
    this.actionKey,
    this.scannable = false,
    this.fromScan,
  });

  final String title;
  final String hint;
  final String action;
  final Key? fieldKey;
  final Key? actionKey;

  /// Whether to offer the wallet's camera, when it has one.
  final bool scannable;

  /// What of a scanned code goes in the field; the whole code when null.
  final String Function(String scanned)? fromScan;

  @override
  State<TextEntryScreen> createState() => _TextEntryScreenState();
}

class _TextEntryScreenState extends State<TextEntryScreen> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() => Navigator.of(context).pop(_text.text.trim());

  @override
  Widget build(BuildContext context) {
    final scan = widget.scannable ? SplitsScope.scannerOf(context) : null;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      bottomNavigationBar: BottomActions(
        children: [
          if (scan != null)
            SecondaryButton(
              key: const Key('splits_text_entry_scan'),
              onPressed: () async {
                final scanned = await scan(context);
                if (scanned == null || !mounted) return;
                setState(
                  () => _text.text = widget.fromScan?.call(scanned) ?? scanned,
                );
              },
              child: const Text('Scan QR'),
            ),
          FilledButton(
            key: widget.actionKey,
            onPressed: _done,
            child: Text(widget.action),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: widget.fieldKey,
            controller: _text,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: (_) => _done(),
          ),
        ],
      ),
    );
  }
}

/// Pushes a [TextEntryScreen] and returns what was entered, or null.
Future<String?> askForText(
  BuildContext context, {
  required String title,
  required String hint,
  required String action,
  Key? fieldKey,
  Key? actionKey,
  bool scannable = false,
  String Function(String scanned)? fromScan,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute<String>(
    builder: (_) => TextEntryScreen(
      title: title,
      hint: hint,
      action: action,
      fieldKey: fieldKey,
      actionKey: actionKey,
      scannable: scannable,
      fromScan: fromScan,
    ),
  ),
);

/// The address in a scanned or pasted code: a bare address, or the one a
/// `zcash:` payment request names before its query.
String zcashAddressIn(String code) {
  var text = code.trim();
  if (text.toLowerCase().startsWith('zcash:')) {
    text = text.substring('zcash:'.length);
    final query = text.indexOf('?');
    if (query >= 0) text = text.substring(0, query);
  }
  return text;
}

/// Asks for [name]'s Zcash address, typed, pasted or scanned, and sets it on
/// the bill for participant [id]. Returns whether one was set.
Future<bool> askAndSetAddress(
  BuildContext context, {
  required String billId,
  required String id,
  required String name,
}) async {
  final address = await askForText(
    context,
    title: '$name’s address',
    hint: 'Zcash address',
    action: 'Save',
    fieldKey: const Key('splits_address_field'),
    actionKey: const Key('splits_address_save'),
    scannable: true,
    fromScan: zcashAddressIn,
  );
  if (address == null || address.trim().isEmpty || !context.mounted) {
    return false;
  }
  final controller = SplitsScope.read(context);
  await controller.setAddressFor(
    billId: billId,
    id: id,
    address: zcashAddressIn(address),
  );
  return controller.lastError == null;
}
