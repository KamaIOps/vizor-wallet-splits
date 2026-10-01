// Two actions in flight: the controller stays busy until the last of them
// finishes, not the first.
import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

/// Storage whose writes of a bill wait, once [hold] is set, until the
/// test releases them.
class _Held extends InMemoryBillStorage {
  bool hold = false;
  final List<Completer<void>> waiting = [];

  @override
  Future<void> write(String key, String value) async {
    if (hold && key.startsWith('splitz_bill_')) {
      final gate = Completer<void>();
      waiting.add(gate);
      await gate.future;
    }
    return super.write(key, value);
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('busy holds until the last of two overlapping actions ends', () async {
    final storage = _Held();
    final c = SplitsController(
      wallet: FakeWallet(),
      store: BillStore(storage),
      keys: SplitsKeys(store: InMemorySecretStore(), random: Random(5)),
    );
    await c.load();
    final a = (await c.createBill(name: 'Dinner', currency: 'USD'))!;
    final b = (await c.createBill(name: 'Lunch', currency: 'USD'))!;
    expect(c.busy, isFalse);

    storage.hold = true;
    final first = c.setRate(billId: a, currency: 'USD', minorUnitsPerZec: 100);
    final second = c.setRate(billId: b, currency: 'USD', minorUnitsPerZec: 200);
    await _until(() => storage.waiting.length == 2);
    expect(storage.waiting, hasLength(2));
    expect(c.busy, isTrue);

    storage.hold = false;
    storage.waiting.first.complete();
    await first;
    expect(c.busy, isTrue, reason: 'the second action is still in flight');

    storage.waiting.last.complete();
    await second;
    expect(c.busy, isFalse);
    expect(c.lastError, isNull);
  });
}
