// A send the wallet could not build, said in ZEC rather than zatoshi.
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/view/naming.dart';

void main() {
  test('the shortfall is said in ZEC, with every digit', () {
    expect(
      describeSendFailure(
        'The wallet could not build this payment: Propose failed: '
        'Insufficient balance (have 0, need 46540327 including fee)',
      ),
      'Not enough ZEC: this payment needs 0.46540327 ZEC including the fee, '
      'and the wallet has 0 ZEC.',
    );
    expect(
      describeSendFailure(
        'insufficient balance (have 150000000, need 200000001 including fee)',
      ),
      'Not enough ZEC: this payment needs 2.00000001 ZEC including the fee, '
      'and the wallet has 1.5 ZEC.',
    );
  });

  test('any other reason is passed on as the wallet wrote it', () {
    expect(describeSendFailure('Nothing was spent.'), 'Nothing was spent.');
    expect(
      describeSendFailure('Insufficient balance (have x, need 5)'),
      'Insufficient balance (have x, need 5)',
    );
  });
}
