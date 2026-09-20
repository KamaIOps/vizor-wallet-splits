/// One wallet a development run is pointed at.
///
/// The shape only: no wallet is named here, so this file is committable while
/// a table of real accounts may not be. `testnet_accounts.dart` holds the
/// testnet set; a mainnet set, if one exists, stays out of the repository.
library;

/// One wallet in the development set.
class DevAccount {
  const DevAccount({
    required this.name,
    required this.seedIndex,
    this.birthdayHeight,
    this.note,
  });

  /// What the wallet is called when a run is described.
  final String name;

  /// Its position in the seed driver's list. The driver is asked for this
  /// index; the phrase itself never travels any other way.
  final int seedIndex;

  /// The height its first note was written at, when that is known.
  ///
  /// A wallet made recently has nothing before this height, so scanning from
  /// it is the difference between a run that takes a minute and one that takes
  /// an hour. Absent means scan from the birthday the wallet itself reports.
  final int? birthdayHeight;

  /// What this wallet is for, where that is not obvious from its balance.
  final String? note;
}
