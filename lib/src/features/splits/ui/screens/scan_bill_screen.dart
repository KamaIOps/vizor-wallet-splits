/// Reading whatever a camera or a clipboard produced.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/host.dart' as splitz;

import '../state/splits_controller.dart';
import 'bill_screen.dart';
import 'splits_scope.dart';

/// Takes a scanned or pasted code and does whatever it turns out to be.
///
/// One entry point, because a person points a camera at a square and does not
/// know which kind it is. The protocol decides: a payload carries more, so it
/// is tried first.
class ScanBillScreen extends StatefulWidget {
  const ScanBillScreen({super.key, this.initialCode});

  /// A code that arrived before the screen did — an opened invite link — read
  /// as though it had been pasted.
  final String? initialCode;

  @override
  State<ScanBillScreen> createState() => _ScanBillScreenState();
}

class _ScanBillScreenState extends State<ScanBillScreen> {
  final _text = TextEditingController();
  String? _message;

  @override
  void initState() {
    super.initState();
    // A code that arrived with a link is shown, not acted on. Opening a link
    // is not agreeing to join the bill it names, and reading an invite keeps
    // its key on this device for good.
    final code = widget.initialCode?.trim();
    if (code != null && code.isNotEmpty) {
      _text.text = code;
      _message = _preview(code);
    }
  }

  /// What [code] is, before anything is done with it.
  String? _preview(String code) {
    final scanned = splitz.readScan(code);
    final invite = switch (scanned) {
      splitz.ScannedInvite(:final invite) => invite,
      splitz.ScannedBill(:final invite) => invite,
      _ => null,
    };
    if (invite == null) return null;
    final expiry = invite.expiry;
    // §11.1: `x` is a hint the sender wrote, compared here against this
    // device's clock and shown rather than enforced.
    // Compared in seconds: `x` may be any of nineteen digits, and scaling it
    // to milliseconds would overflow.
    final nowSeconds =
        SplitsScope.read(context).now().millisecondsSinceEpoch ~/ 1000;
    final expired = expiry != null && expiry < nowSeconds;
    return [
      'An invite to “${invite.name}”.',
      if (expired) 'Its sender marked it as expired.',
      'Joining keeps its key on this device, and anyone else holding this '
          'link can read the bill too.',
    ].join(' ');
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Opens the wallet's camera and reads whatever it produced.
  ///
  /// A cancelled scan returns null and changes nothing: somebody who backed
  /// out of the camera has not asked for anything.
  Future<void> _scan(ScanACode scan) async {
    final code = await scan(context);
    if (!mounted || code == null || code.trim().isEmpty) return;
    _text.text = code.trim();
    await _read();
  }

  /// Takes [key] for [billId], asking first when this device holds another.
  /// False when the person kept the one held, or storing it failed.
  Future<bool> _takeKey(
    SplitsController controller,
    String billId,
    String key,
  ) async {
    if (await controller.holdsOtherKey(billId, key)) {
      if (!mounted) return false;
      final replace = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('A different key for this bill'),
          content: const Text(
            'This device already holds another key for this bill, from an '
            'earlier code or link. Only one of them is the bill the others '
            'use, and a link is text anyone can send. Use this one only if you '
            'got it from the person who opened the bill.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('Keep the one I have'),
            ),
            FilledButton(
              key: const Key('splits_scan_replace_key'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Use this one'),
            ),
          ],
        ),
      );
      if (replace != true) return false;
      await controller.replaceKey(billId, key);
    } else {
      await controller.acceptKey(billId, key);
    }
    if (controller.lastError != null) {
      if (mounted) setState(() => _message = controller.lastError);
      return false;
    }
    return true;
  }

  Future<void> _read() async {
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);
    final scanned = splitz.readScan(_text.text.trim());

    switch (scanned) {
      case splitz.ScannedBill(:final entries, :final invite):
        if (invite == null) {
          // A delta: entries for a bill whose key this device must already
          // hold. Without the bill id there is nothing to merge them into.
          setState(
            () => _message =
                'This code carries changes to a bill, not a bill. Scan the '
                'bill’s own code or its invite first.',
          );
          return;
        }
        if (!await _takeKey(controller, invite.billId, invite.key)) return;
        await controller.accept(invite.billId, entries);
        if (!mounted) return;
        if (controller.lastError != null) {
          setState(() => _message = controller.lastError);
          return;
        }
        navigator.pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => BillScreen(billId: invite.billId),
          ),
        );

      case splitz.ScannedInvite(:final invite):
        if (!await _takeKey(controller, invite.billId, invite.key)) return;
        if (!mounted) return;
        // The invite names the bill; the relay holds its log. Fetch it now,
        // since a bill this device does not hold has no screen of its own to
        // sync from.
        if (controller.hasRelay) {
          await controller.syncBill(invite.billId);
          if (!controller.bills.any((b) => b.id == invite.billId)) {
            await controller.load();
          }
          if (!mounted) return;
          if (controller.bills.any((b) => b.id == invite.billId)) {
            navigator.pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => BillScreen(billId: invite.billId),
              ),
            );
            return;
          }
        }
        setState(
          () => _message = controller.hasRelay
              ? 'Invite accepted, but the relay does not hold this bill yet. '
                    'Ask for its code, or try again once it has been synced.'
              : 'Invite accepted. The bill itself still has to arrive — scan '
                    'its code.',
        );

      case splitz.ScanRefused(:final code):
        // A §12 code. The message a person reads is derived from it, never
        // written beside it.
        setState(() => _message = _explain(code));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final scan = SplitsScope.scannerOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan a bill')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            scan == null
                // No camera in this build. Said plainly rather than offering
                // a button that leads nowhere.
                ? 'Paste a bill code or an invite. A camera reads the same '
                      'strings, so whatever it produces goes here.'
                : 'Point the camera at a bill code or an invite, or paste one '
                      'in.',
          ),
          if (scan != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              key: const Key('splits_scan_camera'),
              onPressed: controller.busy ? null : () => _scan(scan),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan a code'),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Code',
              hintText: 'splitz1:… or zcash:…?',
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          const SizedBox(height: 16),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(_message!),
            ),
          FilledButton(
            key: const Key('splits_scan_read'),
            onPressed: controller.busy ? null : _read,
            child: Text(widget.initialCode == null ? 'Read it' : 'Join'),
          ),
        ],
      ),
    );
  }

  /// Turns a §12 code into a sentence, and says which code it was.
  ///
  /// The code is kept in the message because it is the part that is the same
  /// in every wallet: it is what somebody can be asked to read out.
  static String _explain(String code) => switch (code) {
    'payload_too_large' =>
      'That bill is too big for one code ($code). Ask for an invite and '
          'let sync bring the rest.',
    'payload_damaged' =>
      'That code did not come through cleanly ($code). Try scanning it '
          'again.',
    'invite_bad_expiry' || 'invite_missing_key' =>
      'That invite is not one this wallet can use ($code).',
    _ => 'That is not a bill code or an invite ($code).',
  };
}
