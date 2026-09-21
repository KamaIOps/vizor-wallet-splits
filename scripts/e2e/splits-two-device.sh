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
root="$(cd "$here/../.." && pwd)"
protocol="${SPLITZ_PROTOCOL:-$HOME/Splitz-Protocol}"
network="${SPLITS_NETWORK:-regtest}"

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

work="$(mktemp -d)"
a_log="$work/a.log"
b_log="$work/b.log"
a_status="$work/a.status"
b_status="$work/b.status"
a_pid=""
b_pid=""

cleanup() {
  [ -n "$a_pid" ] && kill "$a_pid" 2>/dev/null || true
  [ -n "$b_pid" ] && kill "$b_pid" 2>/dev/null || true
  [ -n "$own_relay" ] && kill "$own_relay" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

device() {
  local name="$1" udid="$2" log="$3" status="$4"
  shift 4
  (
    set +e
    (cd "$root" && fvm flutter test integration_test/splits_two_device_test.dart \
      -d "$udid" \
      --dart-define=VIZOR_FORM_FACTOR=mobile \
      --dart-define=ZCASH_DEFAULT_NETWORK="$network" \
      --dart-define=ZCASH_E2E_NETWORK="$network" \
      --dart-define=SPLITS_PHASE="$name" \
      --dart-define=SPLITS_RELAY_URL="$relay" \
      "$@") >"$log" 2>&1
    echo $? >"$status"
  ) &
}

echo "── device a on $UDID_A ──────────────────────────"
device a "$UDID_A" "$a_log" "$a_status"
a_pid=$!

# A prints the invite once the bill is on the relay. Until then there is
# nothing for B to join.
invite=""
for _ in $(seq 1200); do
  invite="$(sed -n 's/.*INVITE \(splitz:\/\/[^ ]*\).*/\1/p' "$a_log" 2>/dev/null | head -1)"
  [ -n "$invite" ] && break
  if [ -f "$a_status" ]; then
    echo "device a exited before printing an invite" >&2
    cat "$a_log" >&2
    exit 1
  fi
  sleep 1
done
if [ -z "$invite" ]; then
  echo "device a printed no invite" >&2
  tail -60 "$a_log" >&2
  exit 1
fi
echo "invite: $invite"

echo "── device b on $UDID_B ──────────────────────────"
device b "$UDID_B" "$b_log" "$b_status" --dart-define="SPLITS_INVITE=$invite"
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
