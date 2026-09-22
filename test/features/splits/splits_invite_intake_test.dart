import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/splits_invite_intake.dart';

void main() {
  test('an invite is read once, and the latest one wins', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final intake = container.read(splitsInviteIntakeProvider.notifier);

    expect(intake.take(), isNull);
    intake.receive('splitz://join?v=1&b=first');
    intake.receive('splitz://join?v=1&b=second');
    expect(intake.take(), 'splitz://join?v=1&b=second');
    expect(intake.take(), isNull);
    expect(container.read(splitsInviteIntakeProvider), isNull);
  });
}
