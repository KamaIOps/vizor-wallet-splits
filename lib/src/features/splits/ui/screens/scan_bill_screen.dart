/// Reading whatever a camera or a clipboard produced.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' show isInviteExpired;

import '../state/splits_controller.dart';
import 'bill_screen.dart';
import '../view/chrome.dart';
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
    // §11.1: `x` is a hint the sender wrote, compared against this device's
    // clock and shown rather than enforced.
    final expired = isInviteExpired(
      invite,
      SplitsScope.read(context).now().millisecondsSinceEpoch ~/ 1000,
    );
    return [
      'An invite to “${invite.name}”.',
      if (expired) 'Its sender marked it as expired.',
      'Anyone with this link can read the bill.',
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
            'This phone has another key for this bill. Keep the one you trust.',
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
                'This is an update, not a bill. Scan the bill first.',
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
        // §11.1: `x` is the sender's hint, shown on every path an invite
        // arrives by rather than only on a link.
        if (isInviteExpired(
          invite,
          controller.now().millisecondsSinceEpoch ~/ 1000,
        )) {
          final join = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              title: const Text('This invite has expired'),
              content: const Text(
                'Its sender marked it as expired. Ask them for a new one, or '
                'join anyway if you trust it.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialog).pop(false),
                  child: const Text('Don’t join'),
                ),
                FilledButton(
                  key: const Key('splits_scan_join_expired'),
                  onPressed: () => Navigator.of(dialog).pop(true),
                  child: const Text('Join anyway'),
                ),
              ],
            ),
          );
          if (join != true) return;
        }
        if (!mounted) return;
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
        // A sync the bill refused names why: a key that is not the bill's
        // is not "not synced yet".
        final state = controller.syncStateOf(invite.billId);
        setState(
          () => _message = state.phase == SplitsSyncPhase.failed
              ? state.detail
              : controller.hasRelay
              ? 'Joined. It hasn’t synced yet, so ask for its code.'
              : 'Joined. Now scan the bill’s code.',
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
      appBar: AppBar(title: const Text('Join a bill')),
      bottomNavigationBar: BottomActions(
        children: [
          if (scan != null)
            SecondaryButton(
              key: const Key('splits_scan_camera'),
              onPressed: controller.busy ? null : () => _scan(scan),
              child: const Text('Scan a code'),
            ),
          FilledButton(
            key: const Key('splits_scan_read'),
            onPressed: controller.busy ? null : _read,
            child: Text(widget.initialCode == null ? 'Read it' : 'Join'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            scan == null
                // No camera in this build. Said plainly rather than offering
                // a button that leads nowhere.
                ? 'Paste a bill code or invite.'
                : 'Scan or paste a bill code or invite.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Code',
              // Only what a bill code reader takes: a payment request is
              // read by the wallet's own send screen, not here.
              hintText: 'splitz1:… or splitz://join?…',
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          const SizedBox(height: 16),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(_message!),
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
    'payload_too_large' => 'Too big for one code ($code). Ask for an invite.',
    'payload_damaged' => 'Couldn’t read that code ($code). Try again.',
    'invite_bad_expiry' || 'invite_missing_key' =>
      'That invite is not one this wallet can use ($code).',
    _ => 'That is not a bill code or an invite ($code).',
  };
}
