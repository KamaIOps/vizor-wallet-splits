# Building the shared-bill feature

The splits feature is two repositories. `pubspec.yaml` reaches the protocol by
relative path, so it must be checked out **as a sibling of this one**, under
the name spelled exactly as below:

```
<parent>/
  Vizor-Wallet/        this repository
  Splitz-Protocol/     the protocol and the wallet plumbing
```

The screens are this repository's own, under `lib/src/features/splits/ui/`.

The two dependencies that require it:

| dependency | resolves to |
|---|---|
| `splitz_host` | `../Splitz-Protocol/splitz_host` |
| `splitz_core` | `../Splitz-Protocol/dart` |

`flutter pub get` fails with an unresolved path dependency if the sibling is
missing or sits elsewhere. A parent directory holding only this repository
cannot build the feature at all.

## Running the lanes

Host tests and the analyzer need nothing but the two checkouts:

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
the same defines. Each device starts once the one before it is running, so only
one platform build writes `build/` at a time.

`splits-two-device.sh`, `splits-ui-settle.sh` and `splits-lanes.sh` run on the
iOS simulators `splits-e2e`, `-b`, `-c` and `-d` by default. With
`SPLITS_PLATFORM=android` they run on Android emulators instead: attached ones
first, then the AVDs named in `SPLITS_AVDS`, one per device, each booted
headless and shut down afterwards. The relay, coordinator and lightwalletd
ports are forwarded to each emulator with `adb reverse`.

```bash
SPLITS_PLATFORM=android scripts/e2e/splits-lanes.sh
```

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
../Splitz-Protocol/tools/relay/funnel.sh     # prints the origin and the define
fvm flutter run -d <phone> \
  --dart-define=SPLITS_RELAY_URL=https://<machine>.<tailnet>.ts.net
```

`funnel.sh` serves the relay through Tailscale Funnel at this machine's tailnet
name, so the origin is the same on every start and a phone is built once. It
keeps what the relay holds in a state file, so a restart loses nothing. It
needs the Tailscale app on this machine, logged in; the phones need nothing.

Without Tailscale, `public.sh` does the same through a Cloudflare quick
tunnel. Its origin (`https://<origin>.trycloudflare.com`) is new each time the
script starts, so a restart means rebuilding every phone, and it holds bills
in memory only: after a restart, devices re-push their logs on the next sync.
The relay holds channel digests and ciphertext only, either way.
