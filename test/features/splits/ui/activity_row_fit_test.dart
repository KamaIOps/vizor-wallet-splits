// The activity list on narrow phones at large text sizes: a long figure and
// the time beside a title fit, or go under it, and nothing runs off the edge.
import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_core/host.dart' as entries;
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'support/screen_harness.dart';

void main() {
  for (final (width, scale, amount) in const [
    (320.0, 1.0, 92233720368),
    (320.0, 1.3, 92233720368),
    (320.0, 1.4, 92233720368),
    (320.0, 1.5, 92233720368),
    (320.0, 1.5, 123456789),
    (320.0, 1.6, 123456789),
    (320.0, 2.0, 92233720368),
    (360.0, 1.5, 92233720368),
    (375.0, 1.3, 12345678),
    (375.0, 1.5, 92233720368),
    (393.0, 1.5, 92233720368),
  ]) {
    testWidgets('an expense of $amount fits at $width@$scale', (t) async {
      await fonts();
      await setSize(t, width, 3.0, scale: scale);
      final c = controllerWith();
      late String id;
      await t.runAsync(() async {
        await c.load();
        id = (await c.createBill(name: 'Trip', currency: 'USD'))!;
        await c.accept(id, [
          entries.joinBill(host: otherHost('ben'), name: 'Ben', payTo: 'u1ben'),
          entries.addExpense(
            host: otherHost('ben'),
            expenseId: 'big',
            paidBy: 'ben',
            amount: amount,
            description: 'Hotel',
            split: <String, dynamic>{
              'type': 'equal',
              'among': ['ben'],
            },
          ),
        ]);
      });
      final seen = await overflows(() async {
        await t.pumpWidget(host(c, ActivityScreen(billId: id)));
        await t.pumpAndSettle();
      });
      expect(seen, isEmpty);
      final figure = find.textContaining(' USD').first;
      expect(t.getRect(figure).right, lessThanOrEqualTo(width));
    });
  }
}
