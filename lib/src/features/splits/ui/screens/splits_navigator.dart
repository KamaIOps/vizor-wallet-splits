/// The feature, with its own navigator under its own scope.
library;

import 'package:flutter/material.dart';

import '../state/splits_controller.dart';
import 'bills_screen.dart';
import 'scan_bill_screen.dart';
import 'splits_scope.dart';

/// Hosts the split-bills screens.
///
/// A [Navigator] of its own, under the [SplitsScope], because the screens push
/// each other. A host that puts the scope below its own navigator — which is
/// what happens when the feature is pushed as one route — would otherwise have
/// every pushed screen land outside the scope and fail to find the controller.
/// That does not show up when the scope wraps the whole app, so it is fixed
/// here rather than left for each host to discover.
///
/// The system back gesture pops this navigator first and the host's only once
/// the feature has nothing left to pop.
class SplitsNavigator extends StatefulWidget {
  const SplitsNavigator({
    super.key,
    required this.controller,
    this.scan,
    this.share,
    this.initialCode,
  });

  final SplitsController controller;

  /// The wallet's camera, or null in a build that has none.
  final ScanACode? scan;

  /// The wallet's share sheet, or null in a build that has none.
  final ShareText? share;

  /// A code to read as soon as the feature opens — an invite link that
  /// launched it. Read on the scan screen, over the bills list, so backing out
  /// of it lands where opening the feature normally does.
  final String? initialCode;

  @override
  State<SplitsNavigator> createState() => SplitsNavigatorState();
}

/// The navigator's state, for a host that has a code to hand over after the
/// feature is already open.
class SplitsNavigatorState extends State<SplitsNavigator> {
  final _navigator = GlobalKey<NavigatorState>();
  final _top = _TopRoute();

  @override
  void initState() {
    super.initState();
    final code = widget.initialCode;
    if (code != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openCode(code);
      });
    }
  }

  /// Reads [code] on the scan screen, pushed over whatever is showing.
  ///
  /// A Join screen already on top is replaced rather than stacked under a
  /// second one: two links opened in a row leave one screen, showing the
  /// later code.
  void openCode(String code) {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: ScanBillScreen.routeName),
      builder: (_) => ScanBillScreen(initialCode: code),
    );
    final top = _top.route;
    if (top != null &&
        top.isCurrent &&
        top.settings.name == ScanBillScreen.routeName) {
      navigator.replace(oldRoute: top, newRoute: route);
    } else {
      navigator.push(route);
    }
  }

  @override
  Widget build(BuildContext context) => SplitsScope(
    controller: widget.controller,
    scan: widget.scan,
    share: widget.share,
    child: PopScope(
      // False while this navigator has something of its own to pop, so a
      // back gesture walks the feature's own screens before leaving it.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final navigator = _navigator.currentState;
        if (navigator != null && navigator.canPop()) {
          navigator.pop();
          return;
        }
        // Nothing of the feature's own is left, so it is left. `pop`, not
        // `maybePop`: `maybePop` asks this same scope again, which refuses
        // again, and the person can never leave.
        Navigator.of(context).pop();
      },
      child: ScrollConfiguration(
        behavior: const _WithScrollbar(),
        child: Navigator(
          key: _navigator,
          observers: [_top],
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const BillsScreen(),
          ),
        ),
      ),
    ),
  );
}

/// The route on top of the feature's navigator.
class _TopRoute extends NavigatorObserver {
  Route<dynamic>? route;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      this.route = route;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      this.route = previousRoute;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == this.route) this.route = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == route) route = newRoute;
  }
}

/// A visible scrollbar on every scrolling screen of the feature, on every
/// platform: a bill's rows run past the fold, and the actions pinned at the
/// foot give no hint that there is more above them.
class _WithScrollbar extends MaterialScrollBehavior {
  const _WithScrollbar();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (details.direction == AxisDirection.left ||
        details.direction == AxisDirection.right) {
      return child;
    }
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: true,
      child: child,
    );
  }
}
