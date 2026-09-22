/// The way into shared bills from the wallet.
///
/// Builds the one controller the splits screens read, with every capability
/// `package:splitz_wallet` asks for answered by this wallet, and then hands
/// over to the screens. It is a screen rather than a provider because Vizor's
/// broadcast takes a `WidgetRef`, which belongs to a widget.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:splitz_host/io.dart';
import 'package:splitz_flutter/splitz_flutter.dart';

import '../../core/network/network_http_client.dart';

import 'testnet_accounts.dart';
import 'splits_prices.dart';
import 'splits_relay.dart';
import 'splits_scanner.dart';
import 'splits_invite_intake.dart';
import 'splits_share.dart';
import 'splits_swaps.dart';

import '../../core/storage/wallet_paths.dart';
import '../../providers/account_provider.dart';
import '../../providers/rpc_endpoint_provider.dart';
import '../../rust/api/wallet.dart' as rust_wallet;
import 'dev_accounts_import.dart';
import 'splits_send.dart';
import 'splits_wallet_adapter.dart';

class SplitsEntryScreen extends ConsumerStatefulWidget {
  const SplitsEntryScreen({super.key});

  @override
  ConsumerState<SplitsEntryScreen> createState() => _SplitsEntryScreenState();
}

class _SplitsEntryScreenState extends ConsumerState<SplitsEntryScreen> {
  SplitsController? _controller;
  String? _error;
  final _navigator = GlobalKey<SplitsNavigatorState>();

  /// The invite a link parked before the controller existed, read once.
  String? _openingInvite;

  @override
  void initState() {
    super.initState();
    _build();
  }

  Future<void> _build() async {
    var account = ref.read(accountProvider).value;

    // A development run points at a seed driver and has no accounts yet. With
    // no driver named this does nothing, which is every shipped build.
    if (account?.activeAccountUuid == null) {
      final imported = await importDevAccounts(
        // The testnet set: the one this repository describes. A mainnet run
        // names its own table, which does not live here.
        accounts: testnetAccounts,
        readAccounts: () => ref.read(accountProvider).value,
        readNotifier: () => ref.read(accountProvider.notifier),
      );
      if (imported > 0) account = ref.read(accountProvider).value;
    }

    final accountUuid = account?.activeAccountUuid;
    if (accountUuid == null) {
      setState(() => _error = 'Open an account before starting a bill.');
      return;
    }

    // The viewing key is what carries this account's splits identity across a
    // reinstall. An account that will not give one up still signs — the seed
    // is then random — and the bills screen says so rather than leaving it to
    // be discovered the day the device is replaced.
    String? viewingKey;
    try {
      final dbPath = await getWalletDbPath();
      viewingKey = await rust_wallet.getAccountUfvk(
        dbPath: dbPath,
        network: ref.read(rpcEndpointProvider).networkName,
        accountUuid: accountUuid,
      );
    } on Object {
      viewingKey = null;
    }

    // Beside the wallet database, which is where this app is allowed to write.
    final directory = Directory(
      '${File(await getWalletDbPath()).parent.path}/splits',
    );

    final wallet = VizorSplitsWallet(
      accountUuid: accountUuid,
      unifiedFullViewingKey: viewingKey,
      sender: WalletSplitsSender(
        payToAddress: account?.activeAddress,
        send: (uri) => proposeAndBroadcastSplitsBatch(
          ref: ref,
          accountUuid: accountUuid,
          // One flow id per attempt: it is what lets the wallet recognise a
          // retry of this send rather than a new one.
          sendFlowId: 'splits-${DateTime.now().microsecondsSinceEpoch}',
          paymentRequestUri: uri,
        ),
      ),
    );

    final controller = SplitsController(
      wallet: wallet,
      store: BillStore(FileBillStorage(directory)),
      // The keychain, not the bill store: a bill key in ordinary storage is a
      // bill key anything that can read the sandbox can use.
      keys: SplitsKeys(store: wallet.secrets),
      // A build given no relay keeps its bills on this device and moves them
      // by code. Saying so is the point — the alternative is a sync indicator
      // that never resolves. A development run names one and the same bill
      // reaches several devices; the requests go through the wallet's own
      // client, so on a build routing through Tor they go over Tor and fail
      // closed rather than being the one path that quietly leaves in the
      // clear.
      relay: splitsRelay(),
      // The wallet's own feed, so the price a bill is fixed at is the price
      // every other screen shows. It answers for USD alone; any other
      // currency stays unpriced until somebody types a figure.
      prices: WalletZecPrices(ref.read),
      // A debt owed in another asset settles through a swap. The default
      // client honours this wallet's privacy setting, so a quote goes out the
      // same way every other request does.
      swaps: splitsSwaps(http: NetworkHttpClient()),
    );
    await controller.load();
    if (!mounted) return;
    setState(() {
      _controller = controller;
      _openingInvite = ref.read(splitsInviteIntakeProvider.notifier).take();
    });
    // A link that landed after the read above but before the navigator
    // existed found nothing to hand it to; the navigator exists now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final arrived = ref.read(splitsInviteIntakeProvider.notifier).take();
      if (arrived != null) _navigator.currentState?.openCode(arrived);
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A link opened while these screens are already up: read it in place.
    ref.listen<String?>(splitsInviteIntakeProvider, (_, next) {
      final navigator = _navigator.currentState;
      if (next == null || navigator == null) return;
      final invite = ref.read(splitsInviteIntakeProvider.notifier).take();
      if (invite != null) navigator.openCode(invite);
    });
    final error = _error;
    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Bills')),
        body: Center(child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(error, textAlign: TextAlign.center),
        )),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // `SplitsNavigator` rather than the scope directly: the feature is pushed
    // as one route here, so its own screens must push onto a navigator that
    // sits under its scope.
    return SplitsNavigator(
      key: _navigator,
      controller: controller,
      initialCode: _openingInvite,
      // The wallet's own scanner. Without it the screens still work from a
      // paste; with it they read the same strings from a camera.
      scan: scanSplitsCode,
      // The platform's share sheet, so a code reaches a message as well as a
      // camera or a clipboard.
      share: shareSplitsCode,
    );
  }
}
