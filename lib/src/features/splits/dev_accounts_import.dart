/// Importing the development wallets, for a run that needs real accounts.
///
/// **Development only, and inert without a driver.** The phrases never enter
/// the build: they are fetched one at a time from a driver on loopback while
/// the run is happening. A phrase passed as `--dart-define` would be compiled
/// into the binary, printed by every tool that dumps a build's defines, and
/// kept in whatever log or screenshot the run produced.
///
///     python3 <splitz_host>/tool/seed-driver.py <seed-file> --port 39200 \
///         --define-file /tmp/driver.json
///     flutter run --dart-define-from-file=/tmp/driver.json
///
/// The file holds `SPLITS_SEED_DRIVER_URL`, whose `<token>` is minted per run;
/// the driver refuses any caller without it. It is readable by its owner only
/// and deleted when the driver stops, where a URL passed as `--dart-define`
/// sits on the command line every process on the machine can read.
///
/// With no `SPLITS_SEED_DRIVER_URL` this asks for nothing and does nothing,
/// which is the state every shipped build is in.
library;

import 'dart:convert';
import 'dart:io';

import 'package:splitz_host/dev.dart';

import 'dev_account.dart';

import '../../../app.dart' show log;
import '../../providers/account_provider.dart';

/// Where the driver is, or empty when this build was given none.
const String seedDriverUrl = String.fromEnvironment('SPLITS_SEED_DRIVER_URL');

/// A floor under every development wallet's birthday, or null for none.
///
/// The wallet scans from the earliest birthday any of its accounts carries, so
/// one account imported without a height drags the whole wallet back to
/// Sapling activation and a run that needed minutes takes an hour.
///
/// **A wallet imported at a floor shows only what it received after it.** That
/// is the right trade for a lane that needs a recipient's address, and the
/// wrong one for a lane that needs its balance, so it is named per run rather
/// than written into the table.
const int devBirthdayFloor = int.fromEnvironment(
  'SPLITS_DEV_BIRTHDAY_FLOOR',
  defaultValue: 0,
);

/// Imports [accounts] from the driver, and returns how many arrived.
///
/// Skips any wallet this device already holds. Does nothing at all when no
/// driver was named, and reports rather than throws when one was named and is
/// not there: a run that quietly started with no accounts fails later,
/// somewhere that names the wrong thing.
///
/// The table is an argument rather than a constant so this works for any set:
/// the testnet wallets in `testnet_accounts.dart`, or a mainnet set that stays
/// out of the repository. Nothing here names a wallet.
Future<int> importDevAccounts({
  required List<DevAccount> accounts,
  required AccountState? Function() readAccounts,
  required AccountNotifier Function() readNotifier,
}) async {
  if (seedDriverUrl.isEmpty) return 0;

  final driver = SeedDriver(origin: Uri.parse(seedDriverUrl), fetch: _fetch);
  if (!await driver.isUp) {
    log(
      redactSeedDriverToken(
        'dev accounts: no seed driver at $seedDriverUrl; importing nothing',
        seedDriverUrl,
      ),
    );
    return 0;
  }

  final existing =
      readAccounts()?.accounts.map((a) => a.name).toSet() ?? <String>{};

  var imported = 0;
  for (final account in accounts) {
    if (existing.contains(account.name)) continue;
    try {
      final seed = await driver.seedAt(account.seedIndex);
      await readNotifier().importAccount(
        mnemonic: seed.phrase,
        name: account.name,
        // A wallet made recently has nothing before this height, so
        // scanning from it is the difference between a run that takes a
        // minute and one that takes an hour.
        birthdayHeight: _birthdayFor(account),
      );
      imported++;
      log('dev accounts: imported ${account.name}');
    } on Object catch (e) {
      // Named, and the run carries on: one wallet the driver cannot serve
      // should not stop the others arriving.
      log(
        redactSeedDriverToken(
          'dev accounts: ${account.name} failed: $e',
          seedDriverUrl,
        ),
      );
    }
  }
  return imported;
}

Future<String> _fetch(Uri url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 400) {
      throw HttpException(
        '${response.statusCode} for '
        '${redactSeedDriverToken('$url', seedDriverUrl)}',
      );
    }
    return body;
  } finally {
    client.close();
  }
}

/// [message] with every path segment of [driverUrl] written as `<token>`.
///
/// The path is the driver's per-run token, and whoever holds it can fetch
/// every phrase the driver serves while it runs. The driver keeps it out of
/// its own request log; a line logged here keeps it out of the app's.
String redactSeedDriverToken(String message, String driverUrl) {
  final segments = Uri.tryParse(driverUrl)?.pathSegments ?? const <String>[];
  var out = message;
  for (final segment in segments) {
    if (segment.isNotEmpty) out = out.replaceAll(segment, '<token>');
  }
  return out;
}

/// The height [account] should be scanned from.
///
/// The larger of what the table knows and the floor this run named, so a
/// wallet with no recorded birthday does not drag the others back with it.
int? _birthdayFor(DevAccount account) {
  if (devBirthdayFloor <= 0) return account.birthdayHeight;
  final known = account.birthdayHeight;
  return known == null || known < devBirthdayFloor ? devBirthdayFloor : known;
}
