# Building the shared-bill feature

The splits feature is three repositories, not one. `pubspec.yaml` reaches the
other two by relative path, so they must be checked out **as siblings of this
one**, under names spelled exactly as below:

```
<parent>/
  Vizor-Wallet/        this repository
  Splitz-Protocol/     the protocol and the wallet plumbing
  splitz-flutter/      the splits screens
```

The three dependencies that require it:

| dependency | resolves to |
|---|---|
| `splitz_host` | `../Splitz-Protocol/splitz_host` |
| `splitz_core` | `../Splitz-Protocol/dart` |
| `splitz_flutter` | `../splitz-flutter` |

`flutter pub get` fails with an unresolved path dependency if any of the three
is missing or sits elsewhere. A parent directory holding only this repository
cannot build the feature at all.

## Running the lanes

Host tests and the analyzer need nothing but the three checkouts:

```bash
fvm flutter pub get
fvm flutter analyze
fvm flutter test
```

The integration lanes drive real screens and need a booted simulator. One at a
time: run concurrently, each passes alone and the controls arrive late enough
in the others that a timeout names the wrong thing.

```bash
fvm flutter test integration_test/splits_ui_walkthrough_test.dart \
  -d <device> \
  --dart-define=VIZOR_FORM_FACTOR=mobile \
  --dart-define=ZCASH_DEFAULT_NETWORK=regtest
```

`splits_ui_methods_test.dart` and `splits_mobile_test.dart` take the same
defines. The multi-device lanes are driven by `scripts/e2e/`, which claims each
device's role from a coordinator at run time, so every device is launched with
the same defines and built once.

## Networks

The network name is `test`, never `testnet`: anything unrecognised is treated
as `main`, and the only symptom is a sync error about the server's tip. Use
`regtest` for anything that must run unattended — it funds itself, while a
public testnet faucet does not.

## Syncing bills between phones

A build syncs through the relay named by `SPLITS_RELAY_URL`, and through none
when it is unset — bills then move only as scanned codes, which fit two people
and one expense once payout addresses are on them. A simulator reaches a relay
on the host's loopback; a phone needs one it can reach over HTTPS, because this
wallet declares no cleartext exception — no `NSAppTransportSecurity` in
`ios/Runner/Info.plist`, no `usesCleartextTraffic` or `networkSecurityConfig`
in the Android manifest:

```bash
../Splitz-Protocol/tools/relay/public.sh     # prints the origin and the define
fvm flutter run -d <phone> \
  --dart-define=SPLITS_RELAY_URL=https://<origin>.trycloudflare.com
```

The origin is new each time the script starts and lives as long as it runs.
The relay holds channel digests and ciphertext only, in memory; after a
restart, devices re-push their logs on the next sync.
