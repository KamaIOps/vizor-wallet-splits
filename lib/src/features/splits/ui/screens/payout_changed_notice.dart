import 'package:flutter/material.dart';

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import '../view/naming.dart';
import 'splits_scope.dart';

/// The card saying [id]'s pay-to address changed, with a control to close it.
///
/// §13: a wallet MUST show a changed pay-to address before it settles to one.
/// Closing is per device and per change ([SplitsController.closeNotice]): a
/// later change to the same person's address shows the card again. The send
/// review repeats it for every output it pays, so closing hides nothing a
/// payer needs. Said to be their doing only when a key binds them (§10.7);
/// otherwise anyone with the invite could have made the change.
class PayoutChangedNotice extends StatelessWidget {
  const PayoutChangedNotice({
    super.key,
    required this.view,
    required this.id,
    required this.who,
    required this.onClosed,
    this.keyPrefix = 'splits_settle_replaced',
  });

  final BillView view;
  final String id;
  final String who;

  /// Called with every notice now closed on this bill.
  final ValueChanged<Set<String>> onClosed;

  /// Names the card `<prefix>_<id>` and its close control
  /// `<prefix>_close_<id>`, so each screen's card is found as its own.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final bound = view.identities.bound.containsKey(id);
    return RowCard(
      key: Key('${keyPrefix}_$id'),
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              bound
                  ? '${payoutChangedLine(who, bound: true)}.'
                  : '${payoutChangedLine(who, bound: false)}. '
                        'Check with them.',
            ),
          ),
          IconButton(
            key: Key('${keyPrefix}_close_$id'),
            tooltip: 'Close',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () async {
              final controller = SplitsScope.read(context);
              await controller.closeNotice(view, id);
              onClosed(await controller.closedNotices(view.id));
            },
          ),
        ],
      ),
    );
  }
}
