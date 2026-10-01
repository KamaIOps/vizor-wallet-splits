import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_secure_store.dart';

const kPaymentLinkClaimWalletDirectoryPrefix = 'payment_link_claim_';

/// Claim-wallet directories are named
/// `payment_link_claim_<network>_<sha256>`. The hash cannot be reversed, so the
/// network segment is the only thing that lets a sweep delete one network's
/// claim wallets without touching another's retained recovery state.
final _paymentLinkClaimWalletDirectoryPattern = RegExp(
  r'^payment_link_claim_[a-z0-9]+_[0-9a-f]{64}$',
);

String paymentLinkClaimWalletDirectoryNameFor({
  required String network,
  required String identityHash,
}) => '$kPaymentLinkClaimWalletDirectoryPrefix${network}_$identityHash';

RegExp _paymentLinkClaimWalletDirectoryPatternFor(String network) => RegExp(
  '^$kPaymentLinkClaimWalletDirectoryPrefix'
  '${RegExp.escape(network)}_[0-9a-f]{64}\$',
);

Future<Directory> getWalletSupportDirectory() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return dir;
}

Future<String> getWalletDbName() async {
  return AppSecureStore.instance.ensureWalletDbName();
}

Future<String> getWalletDbPath() async {
  final dir = await getWalletSupportDirectory();
  final dbName = await getWalletDbName();
  return '${dir.path}${Platform.pathSeparator}$dbName';
}

/// Where the splits feature keeps this device's bills: one directory, with
/// one directory per account inside it.
Future<String> getSplitsDirectoryPath() async {
  final dir = await getWalletSupportDirectory();
  return '${dir.path}${Platform.pathSeparator}splits';
}

/// Where [accountUuid] keeps its bills. Accounts are kept apart: a bill, its
/// send notes and its swap watches belong to the account that holds them,
/// and another account on the same device must neither list nor clear them.
Future<String> getSplitsAccountDirectoryPath(String accountUuid) async =>
    '${await getSplitsDirectoryPath()}${Platform.pathSeparator}'
    '${Uri.encodeComponent(accountUuid)}';

/// Copies bills kept before accounts were kept apart into [accountUuid]'s
/// directory, the first time that account opens the feature: the files
/// directly under the splits directory, which only that layout wrote.
///
/// Copied, not moved. That layout was one store every account on the device
/// shared, so which account wrote a bill or a send note is not recorded; each
/// account starts from all of it, as it saw it before. A send note moved to
/// the first account to open would leave the account that sent it free to
/// pay the same debt again.
///
/// Built beside the account's directory and renamed into place, so an
/// adoption cut short is redone rather than taken for finished. Answers
/// whether this call adopted anything.
Future<bool> adoptLegacySplits(String accountUuid) async {
  final root = Directory(await getSplitsDirectoryPath());
  if (!await root.exists()) return false;
  final into = Directory(await getSplitsAccountDirectoryPath(accountUuid));
  if (await into.exists()) return false;
  final legacy = [
    await for (final e in root.list(followLinks: false))
      if (e is File) e,
  ];
  if (legacy.isEmpty) return false;
  final staging = Directory(
    '${root.path}${Platform.pathSeparator}'
    '.adopting-${Uri.encodeComponent(accountUuid)}',
  );
  if (await staging.exists()) await staging.delete(recursive: true);
  await staging.create();
  for (final file in legacy) {
    final name = file.uri.pathSegments.last;
    await file.copy('${staging.path}${Platform.pathSeparator}$name');
  }
  await staging.rename(into.path);
  return true;
}

/// Deletes the bills [accountUuid] held. Their keys are deleted apart, from
/// the keychain (`AppSecureStore.deleteSplitsSecretsFor`).
Future<void> deleteSplitsForAccount(String accountUuid) async {
  final directory = Directory(await getSplitsAccountDirectoryPath(accountUuid));
  if (await directory.exists()) await directory.delete(recursive: true);
}

/// Deletes every bill this device holds. Their keys are in secure storage,
/// which a reset wipes with the rest; a bill left behind would be listed to
/// the next wallet on this device with no key to read it.
Future<void> deleteSplitsDirectory({
  Future<String> Function() resolveDirectory = getSplitsDirectoryPath,
}) async {
  final directory = Directory(await resolveDirectory());
  if (await directory.exists()) await directory.delete(recursive: true);
}

Future<String> getTorDataDirectoryPath() async {
  final dir = await getWalletSupportDirectory();
  return '${dir.path}${Platform.pathSeparator}tor';
}

/// Deletes claim-wallet directories for [network] only, or for every network
/// when it is null.
Future<void> deletePaymentLinkClaimWalletDirectories({
  String? network,
  Future<Directory> Function() resolveSupportDirectory =
      getWalletSupportDirectory,
  Future<void> Function(Directory directory)? deleteDirectory,
}) async {
  final pattern = network == null
      ? _paymentLinkClaimWalletDirectoryPattern
      : _paymentLinkClaimWalletDirectoryPatternFor(network);
  final supportDirectory = await resolveSupportDirectory();
  if (!await supportDirectory.exists()) return;

  Object? firstError;
  StackTrace? firstStackTrace;
  await for (final entity in supportDirectory.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final directoryName = entity.path.split(Platform.pathSeparator).last;
    if (!pattern.hasMatch(directoryName)) {
      continue;
    }
    try {
      if (deleteDirectory == null) {
        await entity.delete(recursive: true);
      } else {
        await deleteDirectory(entity);
      }
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

/// Scoped to both the wallet instance and network; never overlaps claim DBs.
Future<String> getGiftCardTrackingDbPath(String network) async {
  if (!RegExp(r'^[a-z0-9]+$').hasMatch(network)) {
    throw ArgumentError.value(network, 'network');
  }
  final support = await getWalletSupportDirectory();
  final walletName = await getWalletDbName();
  final directory = Directory(
    '${support.path}${Platform.pathSeparator}gift_card_tracking_${walletName}_$network',
  );
  await directory.create(recursive: true);
  return '${directory.path}${Platform.pathSeparator}observer.db';
}

Future<void> deleteGiftCardTrackingDirectories() async {
  final support = await getWalletSupportDirectory();
  await for (final entity in support.list(followLinks: false)) {
    if (entity is Directory &&
        entity.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('gift_card_tracking_')) {
      await entity.delete(recursive: true);
    }
  }
}
