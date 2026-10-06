// §14.11: the creator says a payment arrived for somebody they added by
// hand, who holds no key to say it with, written as that person.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/fake_wallet.dart';

SplitsController _controller() => SplitsController(
  wallet: FakeWallet(),
  store: BillStore(InMemoryBillStorage()),
  keys: SplitsKeys(store: InMemorySecretStore(), random: Random(3)),
  relay: const UnconfiguredSplitsRelay(),
);

/// Ana creates the bill and adds Josh by hand; Cai joins and pays Josh.
Future<(SplitsController, String, String)> _paidJosh() async {
  final c = _controller();
  await c.load();
  final id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
  await c.setRate(billId: id, currency: 'USD', minorUnitsPerZec: 100000);
  await c.addPerson(billId: id, id: 'josh', name: 'Josh');
  await c.setAddressFor(
    billId: id,
    id: 'josh',
    address: 'u1joshpayable000000001',
  );
  final cai = await SignedPeer.named('cai');
  await c.accept(id, [
    await cai.join(id, name: 'Cai', payTo: 'u1caipayable0000000001'),
  ]);
  await c.accept(id, [
    await cai.sign(
      entries.recordPayment(
        host: cai.host,
        paymentId: 'p1',
        to: 'josh',
        amount: 1000,
        reference: 'aa' * 32,
        zatoshi: 1000000,
      ),
      id,
    ),
  ]);
  final payment = c.bills.single.bill.payments.single.id;
  return (c, id, payment);
}

void main() {
  testWidgets('the creator is asked, and says it arrived as Josh', (t) async {
    late (SplitsController, String, String) s;
    await t.runAsync(() async => s = await _paidJosh());
    final (c, id, payment) = s;
    final view = c.bills.single;
    expect(view.awaitingMyConfirmation(c.me).map((p) => p.id), [payment]);
    expect(view.confirmerOf(view.bill.payments.single, c.me), 'josh');

    await t.runAsync(
      () => c.confirmPayment(
        billId: id,
        paymentId: payment,
        method: 'recipientConfirmed',
      ),
    );
    expect(c.lastError, isNull);
    expect(c.bills.single.bill.confirmedPayments, contains(payment));
    expect(c.bills.single.setAside, isEmpty);
    expect(c.bills.single.awaitingMyConfirmation(c.me), isEmpty);
  });

  testWidgets('somebody else on the bill is not asked', (t) async {
    late (SplitsController, String, String) s;
    await t.runAsync(() async => s = await _paidJosh());
    final (c, _, _) = s;
    final view = c.bills.single;
    final cai = view.bill.participants.firstWhere((p) => p.name == 'Cai').id;
    expect(view.awaitingMyConfirmation(cai), isEmpty);
    expect(view.confirmerOf(view.bill.payments.single, cai), isNull);
  });

  testWidgets('the dialog says whose payment it is', (t) async {
    late (SplitsController, String, String) s;
    await t.runAsync(() async => s = await _paidJosh());
    final (c, id, payment) = s;
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(home: ActivityScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(Key('splits_confirm_arrived_$payment')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('splits_confirm_arrived_$payment')));
    await t.pumpAndSettle();
    expect(find.textContaining('You added Josh'), findsOneWidget);
  });

  testWidgets('the bill does not say Josh paid the creator', (t) async {
    late (SplitsController, String, String) s;
    await t.runAsync(() async => s = await _paidJosh());
    final (c, id, _) = s;
    await t.pumpWidget(
      SplitsScope(
        controller: c,
        child: MaterialApp(home: BillScreen(billId: id)),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('a payment waits for you to confirm it'), findsOneWidget);
    expect(find.textContaining('paid you'), findsNothing);
  });
}
