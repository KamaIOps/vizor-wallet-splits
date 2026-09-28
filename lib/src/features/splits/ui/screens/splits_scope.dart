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

  @override
  bool updateShouldNotify(covariant SplitsScope oldWidget) =>
      super.updateShouldNotify(oldWidget) ||
      scan != oldWidget.scan ||
      share != oldWidget.share;
}
