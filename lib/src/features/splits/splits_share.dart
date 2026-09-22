/// The wallet's share sheet, lent to the splits screens.
library;

import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// Hands a bill code or an invite to the platform's share sheet.
///
/// The text goes out exactly as the screen shows it. An invite carries the
/// bill's key, so whatever app it is shared into can open the bill; that is
/// the same reach a copied or photographed code has.
Future<void> shareSplitsCode(
  BuildContext context,
  String text, {
  Rect? origin,
}) async {
  await SharePlus.instance.share(
    ShareParams(text: text, sharePositionOrigin: origin),
  );
}
