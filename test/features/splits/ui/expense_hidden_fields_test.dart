// A figure field that is no longer on screen neither blocks Add nor shows
// another field's text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/ui/splits_ui.dart';

import 'split_screens_test.dart' show billWithTwo, controllerFor, openWith;
import 'support/fake_wallet.dart';

const _notANumber = 'Fix the figure that is not a number.';

Future<void> _tap(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(Key(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key(key)));
  await t.pumpAndSettle();
}

Future<void> _type(WidgetTester t, String key, String text) async {
  await t.ensureVisible(find.byKey(Key(key)));
  await t.enterText(find.byKey(Key(key)), text);
  await t.pumpAndSettle();
}

String? _textOf(WidgetTester t, String key) => t
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

Future<(SplitsController, String)> _open(WidgetTester t) async {
  // Tall enough that the refusal under the last figure is built, so that
  // finding none of it means there is none.
  t.view.physicalSize = const Size(800, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final c = controllerFor(FakeWallet());
  late String id;
  await t.runAsync(() async => id = await billWithTwo(c));
  await openWith(t, c, id, '90.00');
  return (c, id);
}

void main() {
  testWidgets('a bad figure under exact amounts stops blocking once Equal is '
      'chosen', (t) async {
    await _open(t);
    await _tap(t, 'splits_split_exact');
    await _type(t, 'splits_figure_ben', 'abc');
    expect(find.text(_notANumber), findsOneWidget);
    await _tap(t, 'splits_split_equal');
    expect(find.text(_notANumber), findsNothing);
  });

  testWidgets('a bad figure for somebody unticked stops blocking', (t) async {
    final (c, _) = await _open(t);
    await _tap(t, 'splits_split_shares');
    await _type(t, 'splits_figure_${c.me}', '1');
    await _type(t, 'splits_figure_ben', 'x');
    expect(find.text(_notANumber), findsOneWidget);
    await _tap(t, 'splits_sharer_ben');
    expect(find.text(_notANumber), findsNothing);
    // Ticked again, the field shows what the draft holds, and that reads.
    await _tap(t, 'splits_sharer_ben');
    expect(find.text(_notANumber), findsNothing);
  });

  testWidgets('a bad cost on a removed item stops blocking', (t) async {
    await _open(t);
    await _tap(t, 'splits_split_itemized');
    await _tap(t, 'splits_item_add');
    await _type(t, 'splits_item_cost_0', 'x');
    expect(find.text(_notANumber), findsOneWidget);
    await _tap(t, 'splits_item_remove_0');
    expect(find.text(_notANumber), findsNothing);
  });

  testWidgets('a bad figure still on screen still blocks', (t) async {
    await _open(t);
    await _tap(t, 'splits_split_exact');
    await _type(t, 'splits_figure_ben', 'abc');
    await _tap(t, 'splits_split_shares');
    await _tap(t, 'splits_split_exact');
    // The exact field is built anew from the draft, which holds no bad
    // figure; typing one again blocks again.
    expect(find.text(_notANumber), findsNothing);
    await _type(t, 'splits_figure_ben', 'abc');
    expect(find.text(_notANumber), findsOneWidget);
  });

  testWidgets('removing an item shows the next item\'s name and cost', (
    t,
  ) async {
    await _open(t);
    await _tap(t, 'splits_split_itemized');
    await _tap(t, 'splits_item_add');
    await _tap(t, 'splits_item_add');
    await _type(t, 'splits_item_name_0', 'tacos');
    await _type(t, 'splits_item_cost_0', '80.00');
    await _type(t, 'splits_item_name_1', 'beer');
    await _type(t, 'splits_item_cost_1', '10.00');
    await _tap(t, 'splits_item_remove_0');
    expect(find.byKey(const Key('splits_item_name_1')), findsNothing);
    expect(_textOf(t, 'splits_item_name_0'), 'beer');
    expect(_textOf(t, 'splits_item_cost_0'), '10.00');
  });
}
