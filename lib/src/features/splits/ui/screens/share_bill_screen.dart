/// Getting a bill from this phone to another.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:splitz_core/splitz_core.dart' as protocol;

import '../../splits_invite_link.dart';

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import 'splits_scope.dart';

/// One code that brings somebody onto a bill: the invite, or — with
/// [wholeBill] — the whole bill as one code while it still fits.
///
/// They are not interchangeable. An invite carries the bill's id and its key
/// and nothing else — the log still has to arrive from the relay. The payload
/// carries the log itself, so a joiner holds a bill with no network at all.
class ShareBillScreen extends StatefulWidget {
  const ShareBillScreen({
    super.key,
    required this.billId,
    this.wholeBill = false,
  });

  final String billId;

  /// Show the whole-bill code instead of the invite.
  final bool wholeBill;

  @override
  State<ShareBillScreen> createState() => _ShareBillScreenState();
}

class _ShareBillScreenState extends State<ShareBillScreen> {
  String? _inviteLink;
  String? _payload;
  bool _tooBig = false;
  bool _loaded = false;

  /// Why the code could not be drawn, or null.
  String? _failed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _build();
    }
  }

  @override
  void didUpdateWidget(ShareBillScreen old) {
    super.didUpdateWidget(old);
    if (old.billId != widget.billId || old.wholeBill != widget.wholeBill) {
      _inviteLink = null;
      _payload = null;
      _tooBig = false;
      _failed = null;
      _build();
    }
  }

  /// Whether a load begun for [asked] has been overtaken: the screen is gone,
  /// or a different bill or code has been asked for and its own load answers.
  bool _stale(ShareBillScreen asked) =>
      !mounted ||
      asked.billId != widget.billId ||
      asked.wholeBill != widget.wholeBill;

  Future<void> _build() async {
    final controller = SplitsScope.read(context);
    final asked = widget;
    String? invite;
    String? payload;
    try {
      if (widget.wholeBill) {
        payload = await controller.shareableBill(widget.billId);
      } else {
        // An invite says when its sender stops standing behind it (§11.1).
        // Long enough for a code shown at the table to be scanned days later.
        invite = await controller.inviteFor(
          widget.billId,
          expiry: controller.now().add(const Duration(days: 30)),
        );
      }
    } on Object catch (error) {
      // Both codes carry the bill's key. A key store that cannot be read
      // leaves nothing to draw, and that is said rather than left loading.
      if (_stale(asked)) return;
      final held = controller.bills.any((b) => b.id == widget.billId);
      setState(
        () => _failed = !held
            ? 'This device no longer holds this bill.'
            : error is StateError
            ? 'This bill’s key couldn’t be read. Unlock the wallet and open '
                  'this again.'
            : SplitsController.describe(error),
      );
      return;
    }
    if (_stale(asked)) return;
    setState(() {
      if (invite != null) {
        _inviteLink = protocol.renderInviteLink(
          protocol.parseInvite(invite),
          splitsInviteLinkBase,
        );
      }
      _payload = payload;
      // Null is a state, not a failure: §11.2 caps a payload, and a bill with
      // several addressed people reaches that cap quickly.
      _tooBig = widget.wholeBill && payload == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasRelay = SplitsScope.of(context).hasRelay;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.wholeBill ? 'Bill code' : 'Share this bill'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_failed != null)
            NoticeCard(
              key: const Key('splits_share_failed'),
              message: _failed!,
              error: true,
            )
          else if (_payload != null)
            _Code(label: 'Bill code', about: _billSentence, value: _payload!)
          else if (_tooBig)
            NoticeCard(
              key: const Key('splits_share_too_big'),
              message: hasRelay
                  ? 'This bill is too big for one code. Share the invite: '
                        'whoever joins with it gets the bill from the relay.'
                  : 'This bill is too big for one code, and this build has '
                        'no bill relay to send it through. Nobody can join '
                        'it from this phone.',
            )
          else if (_inviteLink != null)
            _Code(
              label: 'Invite',
              about: inviteSentence,
              // The https link, in the code as in a message: a phone's
              // camera hands a custom scheme to whichever app claims it,
              // and this key with it. Every scanner here reads the link as
              // the invite.
              value: _inviteLink!,
            )
          else
            const _Loading(),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(12),
    child: LinearProgressIndicator(),
  );
}

/// A code, drawn, and offered to copy or share.
///
/// Reading a code needs a camera, which is the wallet's; drawing one is done
/// here. A scan, a paste and a shared message are interchangeable because
/// every reader accepts both the code and the link it is shared as.
class _Code extends StatelessWidget {
  const _Code({required this.label, required this.about, required this.value});

  final String label;

  /// What scanning the code gives, in one sentence.
  final String about;
  final String value;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The label centred over the code, in the same style as the
          // sentence under it; the actions sit at the end without moving it.
          Stack(
            alignment: Alignment.center,
            children: [
              Text(label, textAlign: TextAlign.center),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: value)),
                    ),
                    if (SplitsScope.sharerOf(context) case final share?)
                      Builder(
                        builder: (button) => IconButton(
                          key: Key('splits_share_$label'),
                          tooltip: 'Share',
                          icon: const Icon(Icons.share),
                          onPressed: () =>
                              share(button, value, origin: _globalRect(button)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Center(
            child: CodeImage(key: Key('splits_qr_$label'), value: value),
          ),
          const SizedBox(height: 8),
          // One sentence: what scanning gives, which is also the warning.
          Text(
            about,
            key: Key('splits_code_warning_$label'),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

const double _qrSize = 240;

/// What scanning the whole-bill code gives.
const String _billSentence =
    'Anyone who scans this sees the whole bill and can add to it.';

/// What scanning the invite gives.
const String inviteSentence =
    'Anyone who scans this can join the bill and add to it.';

/// A code drawn as a QR image, holding the string it draws.
class CodeImage extends StatelessWidget {
  const CodeImage({super.key, required this.value});

  /// What the image encodes, byte for byte.
  final String value;

  // §11.2 caps a payload at what a version-40 QR holds in byte mode at error
  // correction M, so those are the settings: a lower version could not carry
  // a payload the protocol says fits, and a higher correction level would
  // cap it lower than the protocol does.
  @override
  Widget build(BuildContext context) => QrImageView(
    data: value,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.M,
    size: _qrSize,
    padding: EdgeInsets.all(_quietZone(value)),
    // White behind the modules whatever the theme is: a scanner reads
    // contrast, and a dark-mode card behind a dark code is one that does
    // not scan.
    backgroundColor: const Color(0xFFFFFFFF),
  );
}

/// The white margin around the code, in logical pixels: four modules on every
/// side, which ISO/IEC 18004 requires for a scanner to find the finder
/// patterns. With `m` modules across and `p` padding, a module is
/// `(size - 2p) / m`, so `p = 4 * size / (m + 8)`.
double _quietZone(String value) {
  final code = QrValidator.validate(
    data: value,
    errorCorrectionLevel: QrErrorCorrectLevel.M,
  ).qrCode;
  if (code == null) return 10;
  return 4 * _qrSize / (code.moduleCount + 8);
}

/// Where [context]'s box sits on screen, or null before it has been laid out.
Rect? _globalRect(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
