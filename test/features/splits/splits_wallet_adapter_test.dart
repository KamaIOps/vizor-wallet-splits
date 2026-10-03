/// Where the screens' interfaces meet this wallet's own APIs.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitz_host/splitz_host.dart';
import 'package:zcash_wallet/src/features/splits/dev_account.dart';
import 'package:zcash_wallet/src/features/splits/dev_accounts_import.dart';
import 'package:zcash_wallet/src/features/splits/splits_wallet_adapter.dart';

WalletSplitsSender _sender({
  String? payTo = 'u1me',
  Future<WalletSendOutcome> Function(String)? send,
}) => WalletSplitsSender(
  payToAddress: payTo,
  send:
      send ??
      (uri) async =>
          const WalletSendOutcome(phase: WalletSendPhase.succeeded, txid: 'tx'),
);

VizorSplitsWallet _wallet({
  List<int>? identitySecret = const [1, 2, 3],
  Uint8List Function(int)? randomBytes,
  DateTime Function()? clock,
}) => VizorSplitsWallet(
  accountUuid: 'account-1',
  identitySecret: identitySecret,
  sender: _sender(),
  secrets: _MemorySecrets(),
  randomBytes: randomBytes,
  clock: clock,
);

class _MemorySecrets implements SecretStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

void main() {
  group('the account the package sees', () {
    test('carries the uuid and the identity secret it was given', () {
      final w = _wallet();
      expect(w.account.id, 'account-1');
      expect(w.account.identitySecret, [1, 2, 3]);
    });

    test('a wallet with no secret still has an account', () {
      // The secret is what makes the splits identity survive a reinstall;
      // a hardware account has none on the phone and is still usable, so
      // this is a state rather than a failure.
      expect(_wallet(identitySecret: null).account.identitySecret, isNull);
    });

    test(
      'the secret is the mnemonic and passphrase, joined by a zero byte',
      () {
        expect(identitySecretFromMnemonic(mnemonic: 'ab', passphrase: 'c'), [
          0x61,
          0x62,
          0,
          0x63,
        ]);
        // A passphrase selects a different wallet, so it selects a different
        // identity.
        expect(
          identitySecretFromMnemonic(mnemonic: 'ab', passphrase: ''),
          isNot(identitySecretFromMnemonic(mnemonic: 'ab', passphrase: 'c')),
        );
      },
    );

    test('two accounts of one mnemonic are two identities, and the first '
        'keeps the one it had', () {
      final first = identitySecretFromMnemonic(mnemonic: 'ab', passphrase: 'c');
      expect(
        identitySecretFromMnemonic(
          mnemonic: 'ab',
          passphrase: 'c',
          accountIndex: 0,
        ),
        first,
      );
      expect(
        identitySecretFromMnemonic(
          mnemonic: 'ab',
          passphrase: 'c',
          accountIndex: 1,
        ),
        [0x61, 0x62, 0, 0x63, 0, 0, 0, 0, 1],
      );
      expect(
        identitySecretFromMnemonic(
          mnemonic: 'ab',
          passphrase: 'c',
          accountIndex: 1,
        ),
        isNot(first),
      );
    });
  });

  group('the clock', () {
    test('is UTC by default', () {
      // §9.3 instants are canonical. A local-time clock here writes entries
      // that two devices in different zones disagree about.
      expect(_wallet().now().isUtc, isTrue);
    });

    test('a supplied clock is used as given', () {
      final fixed = DateTime.utc(2026, 10, 12, 9, 30);
      expect(_wallet(clock: () => fixed).now(), fixed);
    });
  });

  group('randomness', () {
    test('returns exactly the bytes asked for, in range', () {
      final bytes = _wallet().randomBytes(32);
      expect(bytes, hasLength(32));
      expect(bytes.every((b) => b >= 0 && b <= 255), isTrue);
    });

    test('two draws differ', () {
      // §9.4 derives a bill id from a nonce, so two bills opened in one
      // second by one person are the same bill unless this is unpredictable.
      final w = _wallet();
      expect(w.randomBytes(16), isNot(equals(w.randomBytes(16))));
    });

    test('a supplied source is used as given', () {
      final w = _wallet(
        randomBytes: (n) => Uint8List.fromList(List.filled(n, 7)),
      );
      expect(w.randomBytes(3), Uint8List.fromList([7, 7, 7]));
    });

    test('zero bytes is empty, not an error', () {
      expect(_wallet().randomBytes(0), isEmpty);
    });
  });

  group('the sender', () {
    test('passes the request through untouched', () async {
      String? seen;
      final s = _sender(
        send: (uri) async {
          seen = uri;
          return const WalletSendOutcome(
            phase: WalletSendPhase.succeeded,
            txid: 'tx-1',
          );
        },
      );
      final out = await s.send('zcash:?address=u1a&amount=0.1');
      expect(seen, 'zcash:?address=u1a&amount=0.1');
      expect(out.txid, 'tx-1');
    });

    test('no pay-to address is a state, not a failure', () {
      // §8.5 reports a participant with no address as unpayable rather than
      // dropping them from the bill.
      expect(_sender(payTo: null).payToAddress, isNull);
    });
  });

  group('development wallets', () {
    test(
      'a build with no seed driver imports nothing and asks nobody',
      () async {
        // Every shipped build is compiled without the define. If this ever
        // reaches the network, an installed app is fetching seed phrases.
        expect(seedDriverUrl, isEmpty);
        final imported = await importDevAccounts(
          accounts: const [DevAccount(name: 'X', seedIndex: 0)],
          readAccounts: () =>
              fail('accounts must not be read without a driver'),
          readNotifier: () => fail('nothing may be imported without a driver'),
        );
        expect(imported, 0);
      },
    );
  });
}
