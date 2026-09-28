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
  void openCode(String code) {
    _navigator.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => ScanBillScreen(initialCode: code),
      ),
    );
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
        Navigator.of(context).maybePop();
      },
      child: Navigator(
        key: _navigator,
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const BillsScreen(),
        ),
      ),
    ),
  );
}
