/// The wallet's camera, lent to the splits screens.
///
/// The screens take a function rather than a camera: a camera is a plugin,
/// a permission prompt and a lifecycle, and this wallet already has one. This
/// is the whole adaptation.
library;

import 'package:flutter/material.dart';

import '../address_scan/widgets/mobile_address_scan_view.dart';

/// Opens the wallet's scanner and returns whatever it read.
///
/// **Nothing is validated here.** The splits screens hand a scanned string to
/// the protocol, which decides whether it is a bill, an invite, a delta or
/// nothing — and refuses it with a code. Rejecting a string at the camera
/// would be a second reader, with its own idea of what a bill code looks
/// like, in front of the one that actually decides.
Future<String?> scanSplitsCode(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (routeContext) => Scaffold(
          body: MobileAddressScanView(
            caption: 'Scan a bill code or an invite',
            steadyHint: 'Keep the code steady and fully visible.',
            resolve: (raw) async => MobileScanOutcome.accepted(raw),
            onScanned: (raw) => Navigator.of(routeContext).pop(raw),
            onClose: () => Navigator.of(routeContext).pop(),
          ),
        ),
      ),
    );
