/// Closing a bill for settling in a test (§14.9), as whichever device
/// created it.
library;

import 'package:splitz_core/host.dart' as splitz;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'fake_wallet.dart';

/// Closes [billId] for settling as its creator: through [c] when [c] opened
/// it, and otherwise as the creator's own device writes it.
Future<void> closeForSettling(SplitsController c, String billId) async {
  final view = c.bills.firstWhere((b) => b.id == billId);
  if (view.creatorId == c.me) {
    await c.closeForSettling(billId);
  } else {
    await c.accept(billId, [
      splitz.closeFor(otherHost(view.creatorId), view.folded!),
    ]);
  }
  final closed = c.bills.firstWhere((b) => b.id == billId).folded?.closed;
  if (closed != true) {
    throw StateError('the bill did not close: ${c.lastError}');
  }
}
