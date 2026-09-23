#!/usr/bin/env bash
# A shared-bill invite opened as a link, on one Android emulator.
#
#   scripts/e2e/splits-invite-link-android.sh
#
# The Android twin of splits-invite-link.sh, over the same test file. Runs
# integration_test/splits_invite_link_test.dart, waits for it to log the invite
# it made, and hands that URI to the emulator as an ACTION_VIEW intent — the
# path a tapped link in Messages takes: the manifest's `splitz://join` filter,
# MainActivity's capture, the payment_uri channel. Passes when the app shows
# the bill.
#
# Uses a running emulator, or boots SPLITS_AVD (default Pixel_10_API_36)
# without a window. The relay from the protocol tree is started on loopback
# and reached from the emulator through `adb reverse`, unless SPLITS_RELAY
# names one.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so a frozen copy can be run from anywhere: bash reads a script
# incrementally, so editing this file mid-run corrupts that run.
root="${VIZOR_ROOT:-$(cd "$here/../.." && pwd)}"
protocol="${SPLITZ_PROTOCOL:-$HOME/Splitz-Protocol}"
APP_ID="${APP_ID:-com.keplr.vizor}"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$sdk/platform-tools/adb"
avd="${SPLITS_AVD:-Pixel_10_API_36}"

emulator_pid=""
serial="$("$adb" devices | awk '/^emulator-[0-9]+\tdevice$/ {print $1; exit}')"
if [ -z "$serial" ]; then
  "$sdk/emulator/emulator" -avd "$avd" -no-window -no-audio -no-snapshot-save \
    >/dev/null 2>&1 &
  emulator_pid=$!
  for _ in $(seq 180); do
    serial="$("$adb" devices | awk '/^emulator-[0-9]+\tdevice$/ {print $1; exit}')"
    [ -n "$serial" ] && break
    sleep 1
  done
  [ -n "$serial" ] || { echo "the emulator $avd did not come up" >&2; exit 1; }
  for _ in $(seq 180); do
    [ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
    sleep 1
  done
fi
echo "device: $serial"

relay="${SPLITS_RELAY:-}"
own_relay=""
if [ -z "$relay" ]; then
  port="${SPLITS_RELAY_PORT:-39300}"
  python3 "$protocol/tools/relay/server.py" --port "$port" &
  own_relay=$!
  relay="http://127.0.0.1:$port"
  for _ in $(seq 40); do
    curl -sf "$relay/c/$(printf '0%.0s' {1..64})" >/dev/null && break
    sleep 0.25
  done
  # The emulator's own loopback, forwarded to this machine's.
  "$adb" -s "$serial" reverse "tcp:$port" "tcp:$port" >/dev/null
fi

work="${SPLITS_WORK:-$(mktemp -d)}"
test_pid=""
# `fvm flutter test` spawns a VM that outlives the wrapper, so the run gets its
# own process group and the group is what is killed.
cleanup() {
  [ -n "$test_pid" ] && { kill -- "-$test_pid" 2>/dev/null || kill "$test_pid" 2>/dev/null; } || true
  [ -n "$own_relay" ] && kill "$own_relay" 2>/dev/null || true
  [ -n "$emulator_pid" ] && { "$adb" -s "$serial" emu kill >/dev/null 2>&1 || kill "$emulator_pid" 2>/dev/null; } || true
  return 0
}
trap cleanup EXIT

# Start from nothing: an uninstall takes the app's data and its keystore
# entries with it, so the create-wallet flow sees its first screen.
"$adb" -s "$serial" uninstall "$APP_ID" >/dev/null 2>&1 || true

# Monitor mode puts the job in a process group of its own, whose id is
# its pid, so cleanup can kill the VM `flutter test` leaves behind.
set -m
(
  set +e
  (cd "$root" && fvm flutter test integration_test/splits_invite_link_test.dart \
    -d "$serial" \
    --dart-define=VIZOR_FORM_FACTOR=mobile \
    --dart-define=SPLITS_RELAY_URL="$relay") >"$work/run.log" 2>&1
  echo $? >"$work/run.status"
) &
test_pid=$!
set +m

invite=""
for _ in $(seq 1800); do
  invite="$(sed -n 's/.*INVITE \(splitz:\/\/join?[^[:space:]]*\).*/\1/p' "$work/run.log" | head -1)"
  [ -n "$invite" ] && break
  [ -f "$work/run.status" ] && break
  sleep 1
done
if [ -z "$invite" ]; then
  echo "the lane never logged an invite" >&2
  tail -60 "$work/run.log" >&2
  exit 1
fi

# The device shell parses the command line again, so the URI is quoted for it:
# unquoted, its `&` would end the command there.
echo "opening the invite on $serial"
"$adb" -s "$serial" shell am start -W -a android.intent.action.VIEW \
  -d "'$invite'" "$APP_ID"
sleep 5
"$adb" -s "$serial" exec-out screencap -p >"$work/after-open.png" 2>/dev/null &&
  echo "screenshot: $work/after-open.png"

wait "$test_pid" 2>/dev/null || true
code="$(cat "$work/run.status" 2>/dev/null || echo 1)"
cat "$work/run.log"
if [ "$code" != 0 ]; then
  echo "the invite link lane failed (exit $code)" >&2
  exit 1
fi
grep -q 'JOINED ' "$work/run.log" || { echo "exit 0 without JOINED" >&2; exit 1; }
echo "── an opened invite link reached the bill, on Android ──"
