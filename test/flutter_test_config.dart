import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/storage/linux_keyring_coordinator.dart';

/// Runs before every test file under `test/`.
///
/// On a Linux host every `AppSecureStore.instance` storage call goes through
/// the process-wide [LinuxKeyringCoordinator] queue. Each case restarts that
/// queue so it never waits on a future left by an earlier case's fake-async
/// zone.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(LinuxKeyringCoordinator.instance.resetStorageQueueForTesting);
  await testMain();
}
