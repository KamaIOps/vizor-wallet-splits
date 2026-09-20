/// The testnet wallets a development run is pointed at.
///
/// **No secret is in this file and none may be put in one.** A seed phrase
/// reaches a build from a driver on loopback at run time, never from a
/// `--dart-define`, a constant, or anything that lands in a binary or a
/// screenshot. What is here is the index each wallet answers to and the
/// birthday height that keeps its scan short — both public, and both useless
/// without the phrase.
///
/// These are **testnet** wallets, minted fresh by
/// `tools/testnet/mint` in the protocol tree, which writes the phrases to a
/// file it never prints. That is why this table may be committed where the
/// mainnet one may not: a testnet wallet describes nobody's money.
library;

import 'dev_account.dart';

/// The testnet chain tip when these wallets were minted, less a margin.
///
/// They were created after this height and have nothing before it, so a scan
/// that starts here misses nothing and skips 4.37 million blocks. The margin
/// covers the hours between minting and the first funding. Tip was 4371581 on
/// 2026-09-21, read from `testnet.zec.rocks:443` — `GetLightdInfo` reported
/// chain `test`, branch `37a5165b`.
///
/// A birthday *later* than a wallet's first note is the one direction that
/// costs money: the block holding that note is never scanned, so the note
/// cannot be seen or spent. Too early only costs scanning.
const int mintedAt = 4371000;

/// Four wallets, in the order the seed driver serves them: index N is line N
/// of the seed file.
const List<DevAccount> testnetAccounts = [
  DevAccount(
    name: 'TAZ-1',
    seedIndex: 0,
    birthdayHeight: mintedAt,
    note: 'the wallet a run spends from — fund this one first',
  ),
  DevAccount(name: 'TAZ-2', seedIndex: 1, birthdayHeight: mintedAt),
  DevAccount(name: 'TAZ-3', seedIndex: 2, birthdayHeight: mintedAt),
  DevAccount(name: 'TAZ-4', seedIndex: 3, birthdayHeight: mintedAt),
];

/// The account at [seedIndex], or null when the driver serves no such wallet.
DevAccount? testnetAccountAt(int seedIndex) {
  for (final account in testnetAccounts) {
    if (account.seedIndex == seedIndex) return account;
  }
  return null;
}
