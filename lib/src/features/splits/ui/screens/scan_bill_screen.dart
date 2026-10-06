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

  /// The name its routes carry, so a second code replaces this screen
  /// rather than stacking another over it.
  static const String routeName = 'splits/join';

  /// A code that arrived before the screen did — an opened invite link — read
  /// as though it had been pasted.
  final String? initialCode;

  @override
  State<ScanBillScreen> createState() => _ScanBillScreenState();
}

class _ScanBillScreenState extends State<ScanBillScreen> {
  final _text = TextEditingController();

  /// What this person is called on the bill. Asked here, beside the code, so
  /// one tap takes the bill and puts them on it.
  final _name = TextEditingController();
  String? _message;

  /// The name to join a bill under once it arrives, for an invite whose bill
  /// the relay did not yet hold when Join was tapped.
  String? _joinAs;

  /// Whether an activation is being acted on. Set before the first await,
  /// so a second tap in the same frame starts nothing.
  bool _joining = false;

  /// Whether the bill is being fetched or merged: shown, since a relay can
  /// take seconds to answer. Not set while a dialog waits on the person.
  bool _fetching = false;

  /// A bill whose key this device took and whose log the relay did not yet
  /// hold, polled while this screen stays open.
  String? _awaiting;
  SplitsController? _poller;

  /// Said when this phone's key store cannot be read.
  static const String _keysUnreadable =
      'This phone’s keys couldn’t be read. Unlock the wallet and try again.';

  @override
  void initState() {
    super.initState();
    // A code is shown, not acted on, until the person taps Join. Opening a
    // link or pointing a camera is not agreeing to join the bill it names,
    // and reading an invite keeps its key on this device for good.
    final code = widget.initialCode?.trim();
    if (code != null && code.isNotEmpty) _text.text = code;
    _text.addListener(_edited);
    _name.addListener(_edited);
  }

  void _edited() {
    if (mounted) setState(() {});
  }

  /// What [code] is, before anything is done with it.
  ///
  /// The name is the one its sender wrote, and is said to be: an invite's
  /// name is free text, and not the bill's own until the bill arrives.
  String? _preview(String code) {
    final scanned = splitz.readScan(code);
    final (invite, what) = switch (scanned) {
      splitz.ScannedInvite(:final invite) => (invite, 'An invite to'),
      splitz.ScannedBill(:final invite?) => (invite, 'A bill code for'),
      _ => (null, ''),
    };
    if (invite == null) return null;
    var name = invite.name.trim();
    // A bill code's invite carries no name; the bill's create does.
    if (name.isEmpty && scanned is splitz.ScannedBill) {
      for (final e in scanned.entries) {
        if (e['kind'] == 'createBill' && e['name'] is String) {
          name = (e['name'] as String).trim();
          break;
        }
      }
    }
    // §11.1: `x` is a hint the sender wrote, compared against this device's
    // clock and shown rather than enforced.
    final expired = isInviteExpired(
      invite,
      SplitsScope.read(context).now().millisecondsSinceEpoch ~/ 1000,
    );
    return [
      name.isEmpty
          ? '$what a bill with no name.'
          : '$what “$name”, as its sender named it.',
      if (expired) 'Its sender marked it as expired.',
      'Anyone with this link can read the bill.',
    ].join(' ');
  }

  @override
  void dispose() {
    _text.removeListener(_edited);
    _name.removeListener(_edited);
    _text.dispose();
    _name.dispose();
    if (_awaiting case final billId?) _poller?.stopPolling(billId);
    super.dispose();
  }

  /// Opens the wallet's camera and puts whatever it produced in the field.
  ///
  /// A cancelled scan returns null and changes nothing: somebody who backed
  /// out of the camera has not asked for anything. Nothing is joined until
  /// Join is tapped.
  Future<void> _scan(ScanACode scan) async {
    final code = await scan(context);
    if (!mounted || code == null || code.trim().isEmpty) return;
    _text.text = code.trim();
  }

  /// Takes the code's bill and joins it under the name given.
  Future<void> _activate() async {
    if (_joining) return;
    setState(() {
      _joining = true;
      _message = null;
    });
    try {
      await _read();
    } finally {
      if (mounted) {
        setState(() => _joining = false);
      } else {
        _joining = false;
      }
    }
  }

  /// Takes [key] for [billId], asking first when this device holds another.
  /// False when the person kept the one held, or storing it failed.
  Future<bool> _takeKey(
    SplitsController controller,
    String billId,
    String key,
  ) async {
    final bool other;
    final bool refused;
    try {
      other = await controller.holdsOtherKey(billId, key);
      refused = other && await controller.heldBillRefusesKey(billId, key);
    } on Object {
      if (mounted) setState(() => _message = _keysUnreadable);
      return false;
    }
    final String? failed;
    if (other) {
      // The bill this phone holds names its own key, so there is nothing to
      // ask: replaceKey refuses this one and says why.
      if (refused) {
        final failed = await controller.failureOf(
          () => controller.replaceKey(billId, key),
        );
        if (mounted) setState(() => _message = failed);
        return false;
      }
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
      failed = await controller.failureOf(
        () => controller.replaceKey(billId, key),
      );
    } else {
      failed = await controller.failureOf(
        () => controller.acceptKey(billId, key),
      );
    }
    if (failed != null) {
      if (mounted) setState(() => _message = failed);
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
        final failed = await controller.failureOf(
          () => _fetch(() => controller.accept(invite.billId, entries)),
        );
        if (!mounted) return;
        if (failed != null) {
          setState(() => _message = failed);
          return;
        }
        if (!await _joinUnder(controller, invite.billId)) return;
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
          await _fetch(() async {
            await controller.syncBill(invite.billId);
            if (!controller.bills.any((b) => b.id == invite.billId)) {
              await controller.load();
            }
          });
          if (!mounted) return;
          if (controller.bills.any((b) => b.id == invite.billId)) {
            if (!await _joinUnder(controller, invite.billId)) return;
            navigator.pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => BillScreen(billId: invite.billId),
              ),
            );
            return;
          }
        }
        final state = controller.syncStateOf(invite.billId);
        // A sync the bill refused names why. A channel that held blobs and
        // opened none under this key is a key that is not this bill's: not
        // "not synced yet". An empty channel is a bill not pushed yet, and
        // is polled for while this screen is open.
        final String message;
        if (state.phase == SplitsSyncPhase.failed) {
          message = state.detail ?? 'Couldn’t fetch this bill.';
        } else if (!controller.hasRelay) {
          message =
              'Joined. This build has no bill relay, so the bill itself '
              'comes as a bill code: ask whoever sent the invite to show '
              'theirs.';
        } else if (state.unopenable > 0) {
          message =
              'This invite’s key doesn’t open what the relay holds for this '
              'bill. Ask whoever sent it for a new invite.';
        } else {
          message =
              'The bill hasn’t reached the relay yet. This screen keeps '
              'checking while it is open and joins you when it arrives. '
              'Later, open the invite again once whoever sent it has '
              'opened the bill.';
          _joinAs = _name.text.trim();
          _await(controller, invite.billId);
        }
        setState(() => _message = message);

      case splitz.ScanRefused(:final code):
        // A §12 code. The message a person reads is derived from it, never
        // written beside it.
        setState(() => _message = _explain(code));
    }
  }

  /// Puts this device on [billId] under the name given, unless it already
  /// is. False, with the reason shown, when the join was refused.
  Future<bool> _joinUnder(
    SplitsController controller,
    String billId, {
    String? name,
  }) async {
    final view = controller.bills.where((b) => b.id == billId).firstOrNull;
    if (view == null) return false;
    if (view.bill.participants.any((p) => p.id == controller.me)) return true;
    final failed = await controller.failureOf(
      () => _fetch(
        () => controller.join(billId, displayName: name ?? _name.text.trim()),
      ),
    );
    if (!mounted) return false;
    if (failed != null) {
      setState(() => _message = failed);
      return false;
    }
    return true;
  }

  /// Runs [work] with the progress bar shown.
  Future<void> _fetch(Future<void> Function() work) async {
    if (mounted) setState(() => _fetching = true);
    try {
      await work();
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  /// Polls [billId] until it arrives or this screen closes.
  void _await(SplitsController controller, String billId) {
    if (_awaiting == billId) return;
    if (_awaiting case final earlier?) _poller?.stopPolling(earlier);
    _awaiting = billId;
    _poller = controller..pollBill(billId);
  }

  /// Opens [_awaiting] once a poll has brought it in.
  void _openArrived(SplitsController controller) {
    final billId = _awaiting;
    if (billId == null || !controller.bills.any((b) => b.id == billId)) {
      return;
    }
    _awaiting = null;
    controller.stopPolling(billId);
    final name = _joinAs;
    _joinAs = null;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (name != null && !await _joinUnder(controller, billId, name: name)) {
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => BillScreen(billId: billId)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final scan = SplitsScope.scannerOf(context);
    _openArrived(controller);
    final idle = !controller.busy && !_joining;
    final code = _text.text.trim();
    final ready = code.isNotEmpty && _name.text.trim().isNotEmpty;
    final about = code.isEmpty ? null : _preview(code);
    return Scaffold(
      appBar: AppBar(title: const Text('Join a bill')),
      bottomNavigationBar: BottomActions(
        children: [
          if (scan != null)
            SecondaryButton(
              key: const Key('splits_scan_camera'),
              onPressed: idle ? () => _scan(scan) : null,
              child: const Text('Scan a code'),
            ),
          FilledButton(
            key: const Key('splits_scan_read'),
            onPressed: idle && ready ? _activate : null,
            child: const Text('Join'),
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
              hintText: 'splitz1:… or https://…/join#…',
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          if (about != null)
            Padding(
              key: const Key('splits_scan_about'),
              padding: const EdgeInsets.only(top: 8),
              child: Text(about),
            ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('splits_scan_name'),
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Your name',
              hintText: 'What others on the bill see',
            ),
          ),
          const SizedBox(height: 16),
          if (_fetching)
            const Padding(
              key: Key('splits_scan_joining'),
              padding: EdgeInsets.only(bottom: 16),
              child: LinearProgressIndicator(),
            ),
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
