# Shared bills

Friends split a bill in the wallet and settle it in ZEC, in another asset by
swap, or in cash. It runs on mobile and opens from **Settings → Split bills**
or from an invite link. The rules behind it are
[Splitz-Protocol](https://github.com/KamaIOps/Splitz-Protocol); this
repository draws the screens.

## Features

- Start a bill, or join one by pasting or scanning its code and typing a name.
- Share a bill as a link or a QR code.
- Add expenses split equally, by amounts, by percentage, by shares or by item.
- Add someone by name, merge them into the person who joined, or take them off.
- Get paid in ZEC, in USDC on a chain the swap provider offers, or in cash.
- Close a bill for settling; any change to its expenses reopens it.
- Pay everyone you owe in one review and one transaction, a swap included.
- Say a payment arrived; a debt counts as paid only then.
- See the bill's history by month, with dates and amounts.
- See how a settled bill was settled, with each payment's transaction.
- Recover a send the app was closed during, without paying twice.

## Try It

The quickest look is the protocol on its own: see **Try it** in
[Splitz-Protocol](https://github.com/KamaIOps/Splitz-Protocol).

To build the app you need [fvm](https://fvm.app) and Rust, then either a Mac
with Xcode (iOS simulators) or Android Studio with its NDK (Android emulators,
on Windows, Linux or macOS). Get both repositories side by side:

```bash
mkdir splitz && cd splitz
git clone https://github.com/KamaIOps/vizor-wallet-splits.git Vizor-Wallet
git clone https://github.com/KamaIOps/Splitz-Protocol.git
cd Vizor-Wallet
fvm install
```

**iOS simulators (macOS).** The first build takes about 20 minutes. Install it
on two simulators (`xcrun simctl list devices` names them):

```bash
fvm flutter build ios --simulator --debug --dart-define=VIZOR_FORM_FACTOR=mobile
xcrun simctl boot <udid>
xcrun simctl install <udid> build/ios/iphonesimulator/Runner.app
xcrun simctl launch <udid> com.keplr.vizor
```

**Android emulators (Windows, Linux, macOS).** The first build takes about
30 minutes. Start two emulators from Android Studio's Device Manager, then
install it on each (`adb devices` names them):

```bash
fvm flutter build apk --debug --dart-define=VIZOR_FORM_FACTOR=mobile
adb -s <device> install build/app/outputs/flutter-apk/app-debug.apk
adb -s <device> shell am start -n com.keplr.vizor/.MainActivity
```

Then split a bill between them, with no money needed:

1. Create a wallet on each.
2. On the first: **Settings → Split bills → New bill**, the share button,
   **Copy**.
3. Move the invite to the second. iOS simulators keep separate clipboards:
   `xcrun simctl pbpaste <first> | xcrun simctl pbcopy <second>`. Android
   emulators share the computer's clipboard. On the second: **Split bills →
   Join a bill**, hold the Code field, **Paste**, type a name, **Join**.
4. Add an expense on each. The creator closes the bill for settling.
5. Whoever owes opens **Settle up** and records a cash payment; the person paid
   opens **Activity** and taps **It arrived**.

Paying in ZEC or by swap needs a little ZEC: the app runs on mainnet.

## Development

The protocol must sit beside this repository, named exactly
`Splitz-Protocol`: `pubspec.yaml` reaches `splitz_host` and `splitz_core` by
relative path (`../Splitz-Protocol/...`), and `flutter pub get` fails without
it.

```bash
fvm flutter pub get
fvm flutter analyze
fvm flutter test
```

The integration lanes drive real screens on a booted simulator, one at a time:

```bash
fvm flutter test integration_test/splits_ui_walkthrough_test.dart \
  -d <device> \
  --dart-define=VIZOR_FORM_FACTOR=mobile \
  --dart-define=ZCASH_DEFAULT_NETWORK=regtest
```

The multi-device lanes are scripts in `scripts/e2e/`: `splits-two-device.sh`,
`splits-ui-settle.sh` and `splits-lanes.sh` run on the simulators `splits-e2e`,
`-b`, `-c` and `-d`, or on Android emulators with `SPLITS_PLATFORM=android`.

## Networks and Sync

The app runs on mainnet. The lanes use `ZCASH_DEFAULT_NETWORK=regtest`, a
local chain that funds itself. The public testnet is `test`, spelled exactly
so; any other value, `testnet` included, falls back to mainnet.

Bills sync through the hosted relay, `https://splitz-relay.splitz.workers.dev`,
with nothing to set up. `--dart-define=SPLITS_RELAY_URL=<origin>` points a
build at another relay; an empty value turns sync off, and bills then move
only as scanned codes. The relay holds only encrypted entries.
