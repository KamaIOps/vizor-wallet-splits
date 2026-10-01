// Names a reader cannot tell apart are one name.
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:zcash_wallet/src/features/splits/ui/view/naming.dart';

void main() {
  test(
    'fullwidth, mathematical and Latin look-alikes read as the plain name',
    () {
      for (final forged in [
        'Ｂｅｎ', // fullwidth
        '\u{1D401}\u{1D41E}\u{1D427}', // mathematical bold
        '\u{1D44F}\u{1D452}\u{1D45B}', // mathematical italic
        '\u{1D539}en', // double-struck capital
      ]) {
        expect(nameSkeleton(forged), 'ben', reason: forged);
      }
      expect(nameSkeleton('ɑna'), 'ana');
      expect(nameSkeleton('Ben\u{1D7CF}'), 'ben1');
    },
  );

  test(
    'an impostor under a fullwidth name is qualified beside the real one',
    () {
      const bill = protocol.Bill(
        id: 'b1',
        name: 'Dinner',
        currency: 'USD',
        participants: [
          protocol.Participant(id: 'ana', name: 'Ana'),
          protocol.Participant(id: 'benbenbenben', name: 'Ben'),
          protocol.Participant(id: 'malmalmalmal', name: 'Ｂｅｎ'),
        ],
      );
      expect(bill.displayNameOf('malmalmalmal'), contains('…'));
      expect(bill.displayNameOf('benbenbenben'), contains('…'));
    },
  );

  test('names that differ still differ', () {
    expect(nameSkeleton('Ben'), isNot(nameSkeleton('Bea')));
    expect(nameSkeleton('Ana'), isNot(nameSkeleton('Anna')));
    expect(nameSkeleton('Ben 2'), isNot(nameSkeleton('Ben')));
  });
}
