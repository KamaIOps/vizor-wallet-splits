/// A shared-bill invite that arrived as an opened link, held until the splits
/// screens can read it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The one invite waiting to be read, or null.
///
/// Memory only: an invite carries the bill's key, and nothing here writes it
/// anywhere. A newer link replaces an older one — the person tapped the second
/// one last. [take] empties it, so an invite is read once.
class SplitsInviteIntake extends Notifier<String?> {
  @override
  String? build() => null;

  void receive(String raw) => state = raw;

  String? take() {
    final raw = state;
    state = null;
    return raw;
  }

  int _screens = 0;

  /// Whether a bills screen is open to read an arriving invite in place.
  ///
  /// Counted by the screen itself rather than read from the router: a pushed
  /// route does not change the location the router reports, so a check on
  /// the location never sees the screen and every link would open another.
  bool get screenOpen => _screens > 0;

  void screenOpened() => _screens++;

  void screenClosed() {
    if (_screens > 0) _screens--;
  }
}

final splitsInviteIntakeProvider =
    NotifierProvider<SplitsInviteIntake, String?>(SplitsInviteIntake.new);
