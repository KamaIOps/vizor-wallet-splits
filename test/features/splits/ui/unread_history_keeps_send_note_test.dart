// §14.3: a note naming its transaction stays while the wallet's history
// cannot be read, so the debt is not offered for a second send.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'settle_send_test.dart' show owingBen;
import 'support/fake_wallet.dart';

const _txid =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

// The wallet built and signed the transaction and named it, but did not
// report the broadcast (§14.3's third outcome).
const _builtNotBroadcast = WalletSendOutcome(
  phase: WalletSendPhase.pendingBroadcast,
  txid: _txid,
);

Future<(SplitsController, String, FakeWallet)> _rig(
  HeldTransactions held,
) async {
  final wallet = FakeWallet(outcome: _builtNotBroadcast);
  final c = SplitsController(
    wallet: wallet,
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
    held: held,
    own: () async => const [],
  );
  final id = await owingBen(c);
  await c.settle(id, (await c.obligation(id))!);
  expect((await c.pendingSend(id))?.txid, _txid);
  return (c, id, wallet);
}

void main() {
  test('control: history readable, tx still waiting -> note kept', () async {
    final (c, id, wallet) = await _rig(
      () async => {_txid: HeldTransaction.waiting},
    );
    await c.resolveSend(id); // "It did not go through"
    await c.settle(id, (await c.obligation(id))!);
    expect(await c.pendingSend(id), isNotNull);
    expect(wallet.sender.sent, hasLength(1));
  });

  test('control: history readable, tx mined -> note kept', () async {
    final (c, id, wallet) = await _rig(
      () async => {_txid: HeldTransaction.mined},
    );
    await c.resolveSend(id);
    expect(await c.pendingSend(id), isNotNull);
  });

  test('history read throws -> the note stays', () async {
    var readable = false;
    final (c, id, wallet) = await _rig(() async {
      if (!readable) throw StateError('wallet db busy');
      return {_txid: HeldTransaction.mined};
    });
    await c.resolveSend(id); // "It did not go through", while history throws
    final cleared = await c.pendingSend(id) == null;
    await c.settle(id, (await c.obligation(id))!);
    readable = true; // the history reads again: the first tx is mined
    // The property the spec states (§14.3): a note naming a transaction the
    // wallet may still broadcast, or has mined, is not removed.
    expect(cleared, isFalse, reason: 'note cleared on an unread history');
  });
}
