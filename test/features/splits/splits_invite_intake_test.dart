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

  test('an open bills screen is known, so a link does not open another', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final intake = container.read(splitsInviteIntakeProvider.notifier);

    expect(intake.screenOpen, isFalse);
    intake.screenOpened();
    expect(intake.screenOpen, isTrue);
    intake.screenClosed();
    expect(intake.screenOpen, isFalse);
    // A close with nothing open does not leave the count below zero.
    intake.screenClosed();
    intake.screenOpened();
    expect(intake.screenOpen, isTrue);
  });
}
