// The fee a send review shows is the ceiling the send is held to (§14.2), as
// the wallet wires it: the preview keeps the fee by request, and the send of
// that request reads it back.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/splits_send.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';
import 'swap_screens_test.dart' show FakeSwaps;

const _fee = 10000;

/// A wallet that builds a proposal at [proposedFee] and sends it through
/// [sendSplitsRequest] under [ceilings], recording what was discarded and
/// what was broadcast.
class _Wallet implements SplitsWallet {
  _Wallet(this.ceilings, {required this.proposedFee});

  final SplitsFeeCeilings ceilings;
  final int proposedFee;
  final FakeWallet _inner = FakeWallet();
  final List<String> discarded = [];
  final List<String> broadcast = [];

  @override
  WalletAccount get account => _inner.account;

  @override
  SecretStore get secrets => _inner.secrets;

  @override
  DateTime now() => _inner.now();

  @override
  Uint8List randomBytes(int byteCount) => _inner.randomBytes(byteCount);

  @override
  late final WalletSender sender = _Sender(this);
}

class _Sender implements WalletSender {
  _Sender(this.w);

  final _Wallet w;

  @override
  String? get payToAddress => 'u1ana000000000000000000';

  @override
  Future<WalletSendOutcome> send(String uri) => sendSplitsRequest<String>(
    uri: uri,
    reviewedFee: w.ceilings.of(uri),
    read: () async => [
      for (final p in protocol.readRequest(uri))
        entries.ProposedOutput(p.address, p.zatoshi),
    ],
    propose: () async => (uri, w.proposedFee),
    discard: (p) async => w.discarded.add(p),
    broadcast: (p) async {
      w.broadcast.add(p);
      return const WalletSendOutcome(
        phase: WalletSendPhase.succeeded,
        txid:
            'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd',
      );
    },
  );
}

/// This device owes Ben 10.00 in ZEC and Cai 5.00 in USDC on Base, closed
/// for settling; previews answer [_fee].
Future<(SplitsController, _Wallet, String)> _bill(int proposedFee) async {
  final ceilings = SplitsFeeCeilings();
  final wallet = _Wallet(ceilings, proposedFee: proposedFee);
  final c = SplitsController(
    wallet: wallet,
    store: BillStore(InMemoryBillStorage()),
    keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
    relay: const UnconfiguredSplitsRelay(),
    swaps: FakeSwaps(),
    own: () async => const [],
    previewSend: (uri) =>
        ceilings.preview(uri, (_) async => const SendPreview(feeZatoshi: _fee)),
  );
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  final ben = otherHost('ben');
  final cai = otherHost('cai');
  await c.accept(id, [
    entries.joinBill(host: ben, name: 'Ben', payTo: 'u1benpayable0000000001'),
    entries.joinBill(
      host: cai,
      name: 'Cai',
      payouts: [
        <String, dynamic>{
          'type': 'swap',
          'asset': 'USDC',
          'chain': 'base',
          'address': '0xcai',
        },
      ],
    ),
    for (final (who, host, x, amount) in [
      ('ben', ben, 'hotel', 2000),
      ('cai', cai, 'cab', 1000),
    ])
      entries.addExpense(
        host: host,
        expenseId: x,
        paidBy: who,
        amount: amount,
        split: <String, dynamic>{
          'type': 'equal',
          'among': [who, c.me]..sort(),
        },
      ),
  ]);
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await c.closeForSettling(id);
  return (c, wallet, id);
}

void main() {
  group('a ZEC payment', () {
    test('at the reviewed fee is broadcast', () async {
      final (c, w, id) = await _bill(_fee);
      final owed = (await c.obligation(id))!;
      await c.previewSend(owed);
      final settled = await c.settle(id, owed);

      expect(w.broadcast, [owed.uri]);
      expect(w.discarded, isEmpty);
      expect(settled!.result, entries.SendResult.sent);
    });

    test('above the reviewed fee is discarded, never broadcast', () async {
      final (c, w, id) = await _bill(_fee + 1);
      final owed = (await c.obligation(id))!;
      await c.previewSend(owed);
      final settled = await c.settle(id, owed);

      expect(settled!.result, entries.SendResult.failed);
      expect(settled.records, isEmpty);
      expect(w.broadcast, isEmpty);
      expect(w.discarded, [owed.uri]);
    });

    test('below the reviewed fee is broadcast', () async {
      final (c, w, id) = await _bill(_fee - 1);
      final owed = (await c.obligation(id))!;
      await c.previewSend(owed);
      await c.settle(id, owed);

      expect(w.broadcast, [owed.uri]);
    });
  });

  group('a combined send (§14.10)', () {
    Future<WalletSendOutcome?> combined(SplitsController c, String id) async {
      final owed = (await c.obligation(id))!;
      final quote = (await c.quoteSwap(
        billId: id,
        to: 'cai',
        amountMinorUnits: 500,
      ))!;
      await c.previewCombined(
        billId: id,
        owed: owed,
        to: 'cai',
        amountMinorUnits: 500,
        quote: quote,
      );
      return c.settleWithSwap(
        billId: id,
        owed: owed,
        to: 'cai',
        amountMinorUnits: 500,
        quote: quote,
      );
    }

    test('the request the review priced is the one sent', () async {
      final (c, w, id) = await _bill(_fee);
      await combined(c, id);

      expect(w.broadcast, hasLength(1));
      expect(w.discarded, isEmpty);
      expect(w.ceilings.of(w.broadcast.single), _fee);
    });

    test('above the reviewed fee is discarded, never broadcast', () async {
      final (c, w, id) = await _bill(_fee + 1);
      final outcome = await combined(c, id);

      expect(outcome!.phase, WalletSendPhase.failed);

      expect(w.broadcast, isEmpty);
      expect(w.discarded, hasLength(1));
      expect(w.ceilings.of(w.discarded.single), _fee);
    });
  });

  test('with no fee reviewed the request is sent as proposed', () async {
    final (c, w, id) = await _bill(_fee * 50);
    final owed = (await c.obligation(id))!;
    await c.settle(id, owed);

    expect(w.ceilings.of(owed.uri!), isNull);
    expect(w.broadcast, [owed.uri]);
  });
}
