/// A provider's base-unit figure, shown in whole tokens.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

void main() {
  test('a figure is shifted by the token\'s own decimals', () {
    expect(formatBaseUnits('9500000', 6), '9.5');
    expect(formatBaseUnits('5', 6), '0.000005');
    expect(formatBaseUnits('0', 6), '0');
    expect(formatBaseUnits('000120', 2), '1.2');
    expect(formatBaseUnits('42', 0), '42');
  });

  test('past 2^63, every digit is kept', () {
    // 2^63 is 9223372036854775808; this is 1.5 * 10^25 base units of a
    // 24-decimal token.
    expect(
      formatBaseUnits('15000000000000000000000001', 24),
      '15.000000000000000000000001',
    );
  });

  test('anything but digits is shown as it came, and labelled', () {
    expect(formatBaseUnits('-5', 6), '-5 base units');
    expect(formatBaseUnits('1e6', 6), '1e6 base units');
  });
}
