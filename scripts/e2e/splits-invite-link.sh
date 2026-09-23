#!/usr/bin/env bash
# A shared-bill invite opened as a link, on one simulator.
#
#   scripts/e2e/splits-invite-link.sh
#
# Runs integration_test/splits_invite_link_test.dart, waits for it to log the
# invite it made, and hands that URI to the simulator with `simctl openurl` —
# the path a tapped link in Messages takes. Passes when the app shows the bill.
#
# Needs the relay from the protocol tree, which this starts unless SPLITS_RELAY
# names one.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so a frozen copy can be run from anywhere: bash reads a script
# incrementally, so editing this file mid-run corrupts that run.
root="${VIZOR_ROOT:-$(cd "$here/../.." && pwd)}"
protocol="${SPLITZ_PROTOCOL:-$HOME/Splitz-Protocol}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.keplr.vizor}"

named_simulator() {
  xcrun simctl list devices available |
    sed -n "s/.*$1 (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1
}
UDID="${SPLITS_UDID_A:-$(named_simulator splits-e2e)}"
[ -n "$UDID" ] || { echo "need a simulator named splits-e2e" >&2; exit 2; }

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
fi

work="${SPLITS_WORK:-$(mktemp -d)}"
test_pid=""
# `fvm flutter test` spawns a VM that outlives the wrapper, so the run gets its
# own process group and the group is what is killed.
cleanup() {
  [ -n "$test_pid" ] && { kill -- "-$test_pid" 2>/dev/null || kill "$test_pid" 2>/dev/null; } || true
  [ -n "$own_relay" ] && kill "$own_relay" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

# A wallet survives a reinstall in the keychain; start from nothing so the
# create-wallet flow sees its first screen.
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl terminate "$UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl keychain "$UDID" reset >/dev/null 2>&1 || true

# Monitor mode puts the job in a process group of its own, whose id is
# its pid, so cleanup can kill the VM `flutter test` leaves behind.
set -m
(
  set +e
  (cd "$root" && fvm flutter test integration_test/splits_invite_link_test.dart \
    -d "$UDID" \
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

# A URL handed over by `simctl` counts as opened from another app, so iOS asks
# "Open in …?" first and waits for a tap nobody makes. The answer lives under
# this key in `com.apple.launchservices.schemeapproval`; writing it is the tap.
xcrun simctl spawn "$UDID" defaults write com.apple.launchservices.schemeapproval \
  "com.apple.CoreSimulator.CoreSimulatorBridge-->splitz" -string "$APP_BUNDLE_ID"

echo "opening the invite on $UDID"
xcrun simctl openurl "$UDID" "$invite"
sleep 5
xcrun simctl io "$UDID" screenshot "$work/after-open.png" >/dev/null 2>&1 &&
  echo "screenshot: $work/after-open.png"

wait "$test_pid" 2>/dev/null || true
code="$(cat "$work/run.status" 2>/dev/null || echo 1)"
cat "$work/run.log"
if [ "$code" != 0 ]; then
  echo "the invite link lane failed (exit $code)" >&2
  exit 1
fi
grep -q 'JOINED ' "$work/run.log" || { echo "exit 0 without JOINED" >&2; exit 1; }
echo "── an opened invite link reached the bill ──"
