import 'dart:io' show Platform;

import 'package:flutter/services.dart';

const _deviceBackupChannel = MethodChannel('com.zcash.wallet/network_privacy');

/// Marks [directory] as excluded from iCloud and Finder backups, creating it
/// if it does not exist yet, so the mark is in place before anything is
/// written into it.
///
/// For state that must not travel to another device through a backup: the
/// Tor directory's guard choice, and the splits bills, which are stored in
/// clear beside keys that live in the keychain.
///
/// Android has no runtime equivalent. `android:allowBackup="false"` keeps app
/// files out of cloud backup, and device-to-device transfer is governed by
/// `res/xml/data_extraction_rules.xml`, whose paths are fixed at build time.
Future<void> excludeFromDeviceBackup(String directory) async {
  if (!Platform.isIOS) return;
  try {
    await _deviceBackupChannel.invokeMethod<void>('excludeFromBackup', {
      'path': directory,
    });
  } on MissingPluginException {
    // Test hosts and older builds have no native side to ask.
  }
}
