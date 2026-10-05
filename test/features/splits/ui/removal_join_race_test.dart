// A join synced in while the removal is planned is either withdrawn too or
// leaves the removal unwritten (§10.8).
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// Lands [inject] in the stored log right after the next armed read of it,
/// returning what was held before: a sync merge between the read and the write.
class LandingStorage extends InMemoryBillStorage {
  Map<String, dynamic>? inject;
  @override
  Future<String?> read(String key) async {
    final v = await super.read(key);
    final e = inject;
    if (e != null && key.startsWith('splitz_bill_') && v != null) {
      inject = null;
      await super.write(key, jsonEncode([...jsonDecode(v) as List, e]));
    }
    return v;
  }
}

void main() {
  for (final land in [false, true]) {
    test('remove Ben, land=$land', () async {
      final storage = LandingStorage();
      final wallet = FakeWallet();
      final c = SplitsController(
        wallet: wallet,
        store: BillStore(storage),
        keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
      );
      await c.load();
      final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
      final ben = await SignedPeer.named('ben');
      await c.accept(id, [
        await ben.join(id, name: 'Ben', payTo: 'u1benold00000000000'),
      ]);
      wallet.tick();
      expect(c.bills.single.bill.participant(ben.id), isNotNull);
      if (land) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        storage.inject = await ben.join(
          id,
          name: 'Ben',
          payTo: 'u1bennew00000000000',
        );
      }
      await c.removePerson(billId: id, id: ben.id);
      expect(
        c.lastError != null || c.bills.single.bill.participant(ben.id) == null,
        isTrue,
        reason: 'said done while Ben is still on the bill',
      );
    });
  }
}
