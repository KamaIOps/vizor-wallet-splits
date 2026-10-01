/// Getting a bill from this phone to another.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:splitz_core/splitz_core.dart' as protocol;

import '../../splits_invite_link.dart';

import 'splits_scope.dart';

/// The invite, and the whole bill as one code when it still fits.
///
/// Two things, not one, because they are not interchangeable. An invite
/// carries the bill's id and its key and nothing else — the log still has to
/// arrive from somewhere. The payload carries the log itself, so a joiner
/// holds a bill rather than a name to go looking for.
class ShareBillScreen extends StatefulWidget {
  const ShareBillScreen({super.key, required this.billId});

  final String billId;

  @override
  State<ShareBillScreen> createState() => _ShareBillScreenState();
}

class _ShareBillScreenState extends State<ShareBillScreen> {
  String? _inviteLink;
  String? _payload;
  bool _tooBig = false;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _build();
    }
  }

  Future<void> _build() async {
    final controller = SplitsScope.read(context);
    // An invite says when its sender stops standing behind it (§11.1). Long
    // enough for a code shown at the table to be scanned days later.
    final invite = await controller.inviteFor(
      widget.billId,
      expiry: controller.now().add(const Duration(days: 30)),
    );
    final payload = await controller.shareableBill(widget.billId);
    if (!mounted) return;
    setState(() {
      _inviteLink = protocol.renderInviteLink(
        protocol.parseInvite(invite),
        splitsInviteLinkBase,
      );
      _payload = payload;
      // Null is a state, not a failure: §11.2 caps a payload, and a bill with
      // several addressed people reaches that cap quickly.
      _tooBig = payload == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Share this bill')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_payload != null) ...[
            _Code(
              label: 'Bill code',
              about: 'Opens the whole bill on another phone.',
              value: _payload!,
            ),
            const SizedBox(height: 16),
          ] else if (_tooBig)
            const _TooBig()
          else
            const _Loading(),
          if (_inviteLink != null)
            _Code(
              label: 'Invite',
              about: 'Lets someone join. The bill arrives when they sync.',
              // The https link, in the code as in a message: a phone's camera
              // hands a custom scheme to whichever app claims it, and this
              // key with it. Every scanner here reads the link as the invite.
              value: _inviteLink!,
            )
          else
            const _Loading(),
        ],
      ),
    );
  }
}

/// A bill past the scan cap.
///
/// Said plainly, because the remedy is different from an error's: nothing is
/// broken, the bill has simply outgrown one code.
class _TooBig extends StatelessWidget {
  const _TooBig();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: 12),
    child: Text('Too big for one code, so share the invite.'),
  );
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

  /// What the code is for, in a line.
  final String about;
  final String value;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: () => Clipboard.setData(ClipboardData(text: value)),
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
          Text(about),
          const SizedBox(height: 8),
          Center(
            child: CodeImage(key: Key('splits_qr_$label'), value: value),
          ),
          const SizedBox(height: 8),
          Text(
            'Anyone with this code can read and add to the bill.',
            key: Key('splits_code_warning_$label'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

const double _qrSize = 240;

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
