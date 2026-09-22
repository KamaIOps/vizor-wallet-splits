#!/usr/bin/env bash
# One bill, two devices, one relay — through the app's own wiring.
#
# Both devices run at the same time, each with its own install for the whole
# run, and neither speaks to the other except by syncing the bill. Device A
# opens the bill and prints an invite; this script reads that line out of A's
# output and starts device B with it. From there each side waits on the relay
# for what the other wrote: a join, two expenses, a payment and the payee's
# confirmation.
#
#   scripts/e2e/splits-two-device.sh
#
# Needs two simulators and the relay from the protocol tree. Set SPLITS_RELAY
# to point at one already running; otherwise this starts and stops its own.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so a frozen copy can be run from anywhere. Bash reads a script
# incrementally from a file offset, so editing this file while a run is in
# flight corrupts that run — copy it, set VIZOR_ROOT, and run the copy.
root="${VIZOR_ROOT:-$(cd "$here/../.." && pwd)}"
protocol="${SPLITZ_PROTOCOL:-$HOME/Splitz-Protocol}"
network="${SPLITS_NETWORK:-regtest}"

# A wallet survives a reinstall. `flutter test` replaces the app bundle, but the
# iOS keychain is not part of it, so a device that ran before boots straight to
# /unlock and the create-wallet flow never sees its first screen. Every device
# starts from nothing, which means terminating, uninstalling and resetting the
# keychain — the last of those is the part a reinstall does not do.
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.keplr.vizor}"
wipe_device() {
  local udid="$1"
  xcrun simctl terminate "$udid" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl keychain "$udid" reset >/dev/null 2>&1 || true
}

named_simulator() {
  xcrun simctl list devices available |
    sed -n "s/.*$1 (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1
}

UDID_A="${SPLITS_UDID_A:-$(named_simulator splits-e2e)}"
UDID_B="${SPLITS_UDID_B:-$(named_simulator splits-e2e-b)}"
if [ -z "$UDID_A" ] || [ -z "$UDID_B" ]; then
  echo "need two simulators: splits-e2e and splits-e2e-b" >&2
  echo "  xcrun simctl create splits-e2e <devicetype> <runtime>" >&2
  exit 2
fi

# One coordinator beside the relay. It hands out the roles the devices used to
# be compiled with, and carries the invite, so both are launched with identical
# defines — one build, and they start together.
coord_port="${SPLITS_COORD_PORT:-39400}"
coordinator="http://127.0.0.1:$coord_port"
python3 "$root/scripts/e2e/splits-coordinator.py" --port "$coord_port" \
  --roles a,b &
own_coord=$!
for _ in $(seq 40); do
  curl -sf "$coordinator/health" >/dev/null && break
  sleep 0.25
done

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
echo "relay: $relay"

xcrun simctl boot "$UDID_A" 2>/dev/null || true
xcrun simctl boot "$UDID_B" 2>/dev/null || true
wipe_device "$UDID_A"
wipe_device "$UDID_B"

work="$(mktemp -d)"
a_log="$work/a.log"
b_log="$work/b.log"
a_status="$work/a.status"
b_status="$work/b.status"
a_pid=""
b_pid=""

# Killing the wrapper does not kill the work: `fvm flutter test` spawns a dart
# VM and a frontend server that outlive it and get reparented. Each device runs
# in its own process group so the group can be killed, and the group is what is
# signalled.
cleanup() {
  [ -n "$a_pid" ] && { kill -- "-$a_pid" 2>/dev/null || kill "$a_pid" 2>/dev/null; } || true
  [ -n "$b_pid" ] && { kill -- "-$b_pid" 2>/dev/null || kill "$b_pid" 2>/dev/null; } || true
  [ -n "$own_relay" ] && kill "$own_relay" 2>/dev/null || true
  [ -n "${own_coord:-}" ] && kill "$own_coord" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

device() {
  local name="$1" udid="$2" log="$3" status="$4"
  shift 4
  (
    set -m
    set +e
    (cd "$root" && fvm flutter test integration_test/splits_two_device_test.dart \
      -d "$udid" \
      --dart-define=VIZOR_FORM_FACTOR=mobile \
      --dart-define=ZCASH_DEFAULT_NETWORK="$network" \
      --dart-define=ZCASH_E2E_NETWORK="$network" \
      --dart-define=SPLITS_COORDINATOR="$coordinator" \
      --dart-define=SPLITS_RELAY_URL="$relay" \
      "$@") >"$log" 2>&1
    echo $? >"$status"
  ) &
}

# Waits for a device's app to be up on its simulator.
#
# Both devices are launched with the same defines and so are one binary, but
# two processes writing this project's single `build/` directory can still
# corrupt each other's artifacts. The second starts once the first is running,
# which costs one build instead of two.
await_running() {
  local log="$1" status="$2" seconds="$3"
  for _ in $(seq "$seconds"); do
    grep -q 'creating wallet' "$log" 2>/dev/null && return 0
    if [ -f "$status" ]; then
      echo "the first device exited before its app started" >&2
      tail -60 "$log" >&2
      return 1
    fi
    sleep 1
  done
  echo "the first device never started its app" >&2
  tail -60 "$log" >&2
  return 1
}

echo "── device on $UDID_A (builds) ───────────────────"
device a "$UDID_A" "$a_log" "$a_status"
a_pid=$!
await_running "$a_log" "$a_status" 1800

echo "── device on $UDID_B ────────────────────────────"
device b "$UDID_B" "$b_log" "$b_status"
b_pid=$!

wait "$a_pid" "$b_pid" 2>/dev/null || true
a_code="$(cat "$a_status" 2>/dev/null || echo 1)"
b_code="$(cat "$b_status" 2>/dev/null || echo 1)"

echo "── device a ─────────────────────────────────────"
cat "$a_log"
echo "── device b ─────────────────────────────────────"
cat "$b_log"

if [ "$a_code" != 0 ] || [ "$b_code" != 0 ]; then
  echo "device a exited $a_code, device b exited $b_code" >&2
  exit 1
fi
echo "── one bill: opened, joined, two expenses, settled, confirmed ──"
