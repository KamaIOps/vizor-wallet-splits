/// How a screen reaches the controller.
library;

import 'package:flutter/widgets.dart';

import '../state/splits_controller.dart';

/// Opens a camera and returns whatever it read, or null if nobody scanned.
///
/// Supplied by the wallet rather than implemented here: a camera is a
/// platform plugin, permissions and a lifecycle, and every wallet embedding
/// these screens already has one. Taking a function keeps this package free
/// of a second camera and of the permission prompt that comes with it.
typedef ScanACode = Future<String?> Function(BuildContext context);

/// Hands [text] to the platform's share sheet.
///
/// Supplied by the wallet for the same reason as [ScanACode]: the sheet is a
/// platform plugin the app already carries. [origin] is the rectangle the
/// tapped control occupies in global coordinates, which an iPad's popover
/// anchors to; null where it is not known.
typedef ShareText =
    Future<void> Function(BuildContext context, String text, {Rect? origin});

/// Opens the Zcash transaction [txid] in the wallet's block explorer, and
/// says whether it could. [txid] is in the order explorers show it.
///
/// Supplied by the wallet, which knows its network and which explorer its
/// person chose.
typedef OpenTransaction = Future<bool> Function(String txid);

/// Hands [SplitsController] down the tree and rebuilds what reads it.
///
/// One controller for the whole feature. Two would be two answers to "what
/// does this device hold", and they would disagree the moment either changed.
class SplitsScope extends InheritedNotifier<SplitsController> {
  const SplitsScope({
    super.key,
    required SplitsController controller,
    required super.child,
    this.scan,
    this.share,
    this.openTransaction,
  }) : super(notifier: controller);

  /// The wallet's camera, or null in a build that has none.
  ///
  /// Null is a state, not a failure: pasting a code works without a camera,
  /// and a screen that offered a scan button leading nowhere would be worse
  /// than one that offers none.
  final ScanACode? scan;

  /// The wallet's share sheet, or null in a build that has none.
  ///
  /// Null leaves copying and the drawn code, which carry the same string.
  final ShareText? share;

  /// The wallet's block explorer, or null in a build that has none.
  final OpenTransaction? openTransaction;

  static SplitsController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SplitsScope>();
    assert(scope != null, 'No SplitsScope above this widget');
    return scope!.notifier!;
  }

  /// The controller without subscribing to it, for a callback that acts rather
  /// than renders.
  static SplitsController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<SplitsScope>();
    assert(scope != null, 'No SplitsScope above this widget');
    return scope!.notifier!;
  }

  /// The wallet's camera, or null where it supplied none.
  static ScanACode? scannerOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SplitsScope>()?.scan;

  /// The wallet's share sheet, or null where it supplied none.
  static ShareText? sharerOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SplitsScope>()?.share;

  /// The wallet's block explorer, or null where it supplied none.
  static OpenTransaction? transactionOpenerOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SplitsScope>()?.openTransaction;

  @override
  bool updateShouldNotify(covariant SplitsScope oldWidget) =>
      super.updateShouldNotify(oldWidget) ||
      scan != oldWidget.scan ||
      share != oldWidget.share ||
      openTransaction != oldWidget.openTransaction;
}

/// What the actions taken on one screen could not do.
///
/// A screen shows [failure] and never [SplitsController.lastError], which is
/// the last failure of any action: shown on open, it puts a refusal from
/// somewhere else beside buttons that did not fail.
mixin SplitsActions<T extends StatefulWidget> on State<T> {
  String? _failure;

  /// What the last action taken here could not do, or null.
  String? get failure => _failure;

  /// Runs [action] as this screen's, and keeps what it could not do as
  /// [failure] in place of what the previous one left. True when it did all
  /// of it.
  Future<bool> act(Future<void> Function() action) async {
    final controller = SplitsScope.read(context);
    if (_failure != null) setState(() => _failure = null);
    final failed = await controller.failureOf(action);
    if (mounted) setState(() => _failure = failed);
    return failed == null;
  }
}

/// Runs [action] as the action of the screen [context] is in, so its failure
/// is shown there. True when it did all of it.
///
/// Reads the screen before anything awaits, while [context] is mounted.
Future<bool> Function(Future<void> Function() action) actionsOf(
  BuildContext context,
) {
  final screen = context.findAncestorStateOfType<SplitsActions>();
  final controller = SplitsScope.read(context);
  return (action) async {
    if (screen != null && screen.mounted) return screen.act(action);
    return await controller.failureOf(action) == null;
  };
}
