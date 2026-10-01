import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/screens/arrivals_screen.dart';
import 'package:zcash_wallet/src/features/splits/ui/state/splits_controller.dart';

const _at = '2026-10-28T19:30:00.000Z';

/// A bill Ana is owed 100.00 USD on, priced at [rate] cents a ZEC, the price
/// set by [setBy].
BillView _view({int rate = 5000, String setBy = 'ana'}) => BillView(
  bill: protocol.Bill(
    id: 'b1',
    name: 'Dinner',
    currency: 'USD',
    participants: const [
      protocol.Participant(id: 'ana', name: 'Ana'),
      protocol.Participant(id: 'ben', name: 'Ben'),
    ],
    rate: protocol.ExchangeRate(
      currency: 'USD',
      minorUnitsPerZec: rate,
      at: _at,
    ),
  ),
  creatorId: 'ana',
  setAside: const [],
  replacedAddresses: const [],
  identities: const protocol.Identities({}),
  entryCount: 4,
  rateSetBy: setBy,
);

splitz.Arrival _arrival({required int zatoshi, required int paidAt}) =>
    splitz.Arrival(
      billId: 'b1',
      record: 'r',
      txid: 'aa00',
      payment: protocol.PaymentRecord(
        id: 'ben:p1',
        from: 'ben',
        to: 'ana',
        amount: 10000,
        currency: 'USD',
        method: 'shieldedZec',
        at: _at,
        zatoshi: zatoshi,
        paidAtRate: protocol.ExchangeRate(
          currency: 'USD',
          minorUnitsPerZec: paidAt,
          at: _at,
        ),
        reference: 'aa00',
      ),
    );

void main() {
  test('an honest payment at the bill price raises nothing', () {
    expect(
      arrivalConcerns(
        arrival: _arrival(zatoshi: 200000000, paidAt: 5000),
        view: _view(),
        live: 5000,
      ),
      isEmpty,
    );
  });

  test('ZEC worth less than it settles at the bill price is named', () {
    // 1,000,000 zat at 5,000 cents a ZEC is 50 cents, against 10,000.
    final said = arrivalConcerns(
      arrival: _arrival(zatoshi: 1000000, paidAt: 1000000),
      view: _view(),
      live: 5000,
    );
    expect(said.first, contains('0.50 USD'));
    expect(said.first, contains('100.00 USD'));
  });

  group('a worth past 2^63-1 is a concern, not a crash', () {
    // 9,200,000,000,000,000,000 cents a ZEC times 2 zat is
    // 18,400,000,000,000,000,000, past 9,223,372,036,854,775,807.
    test('a price near the bound and two zatoshi', () {
      const rate = 9200000000000000000;
      final said = arrivalConcerns(
        arrival: _arrival(zatoshi: 2, paidAt: rate),
        view: _view(rate: rate),
        live: null,
      );
      expect(said, hasLength(1));
      expect(said.single, contains('more than this app can count'));
    });

    // 100,000,000,000 cents a ZEC times 1 ZEC is 10^19.
    test(
      'an ordinary amount at a large price, with the other concerns kept',
      () {
        const rate = 100000000000;
        final said = arrivalConcerns(
          arrival: _arrival(zatoshi: 100000000, paidAt: rate),
          view: _view(rate: rate, setBy: 'ben'),
          live: null,
        );
        expect(said.first, contains('more than this app can count'));
        expect(said, anyElement(contains('set this bill\'s price')));
      },
    );

    // 92,000,000,000 cents a ZEC times 1 ZEC is 9.2 * 10^18, inside.
    test('the largest worth that fits is priced as usual', () {
      const rate = 92000000000;
      expect(
        arrivalConcerns(
          arrival: _arrival(zatoshi: 100000000, paidAt: rate),
          view: _view(rate: rate),
          live: rate,
        ),
        isEmpty,
      );
    });
  });

  test('a price the payer set is named', () {
    final said = arrivalConcerns(
      arrival: _arrival(zatoshi: 5000000, paidAt: 200000),
      view: _view(rate: 200000, setBy: 'ben'),
      live: 100000,
    );
    expect(said, contains("Ben set this bill's price and is the one paying."));
    expect(said.last, contains('100% above'));
  });

  test('no live price is not by itself a concern', () {
    expect(
      arrivalConcerns(
        arrival: _arrival(zatoshi: 200000000, paidAt: 5000),
        view: _view(),
        live: null,
      ),
      isEmpty,
    );
  });
}
