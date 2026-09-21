/// The same four wallets, as a regtest chain sees them.
///
/// A BIP39 phrase is network-agnostic: the seed driver serves one list, and
/// the network decides what addresses come out of it. So these are the testnet
/// wallets again, on a chain this machine owns — which is the difference that
/// matters, because a regtest faucet funds them on demand and mines the
/// confirmations, where a public faucet drips once a day.
///
/// **No birthday.** A regtest chain is a few hundred blocks and is thrown away,
/// so scanning all of it costs nothing, while a height borrowed from another
/// chain would put the wallet's tip ahead of the node's and stall the sync
/// with "lightwalletd tip is behind wallet DB tip". The accounts are imported
/// before they are funded, so nothing lands before the birthday the wallet
/// picks for itself.
library;

import 'dev_account.dart';

const List<DevAccount> regtestAccounts = [
  DevAccount(
    name: 'TAZ-1',
    seedIndex: 0,
    note: 'the wallet a run spends from — fund this one first',
  ),
  DevAccount(name: 'TAZ-2', seedIndex: 1),
  DevAccount(name: 'TAZ-3', seedIndex: 2),
  DevAccount(name: 'TAZ-4', seedIndex: 3),
];
