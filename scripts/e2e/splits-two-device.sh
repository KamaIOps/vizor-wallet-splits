#!/usr/bin/env bash
# One bill, two devices, one relay — through the app's own wiring.
#
# The bill lives on the relay, not on a phone: `flutter test` reinstalls the
# app for every run, so each phase starts from a fresh install and rebuilds
# what it knows by pulling. That is why the create phase prints an invite and
# the join phase is given it — the invite carries the bill id and the key, and
# the log comes from the relay.
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
  trap 'kill $own_relay 2>/dev/null || true' EXIT
  relay="http://127.0.0.1:$port"
  for _ in $(seq 40); do
    curl -sf "$relay/c/$(printf '0%.0s' {1..64})" >/dev/null && break
    sleep 0.25
  done
fi
echo "relay: $relay"

xcrun simctl boot "$UDID_A" 2>/dev/null || true
xcrun simctl boot "$UDID_B" 2>/dev/null || true

phase() {
  local name="$1" udid="$2"
  shift 2
  echo "── phase $name on $udid ─────────────────────────"
  (cd "$root" && fvm flutter test integration_test/splits_two_device_test.dart \
    -d "$udid" \
    --dart-define=VIZOR_FORM_FACTOR=mobile \
    --dart-define=ZCASH_DEFAULT_NETWORK="$network" \
    --dart-define=ZCASH_E2E_NETWORK="$network" \
    --dart-define=SPLITS_PHASE="$name" \
    --dart-define=SPLITS_RELAY_URL="$relay" \
    "$@")
}

create_log="$(mktemp)"
phase create "$UDID_A" | tee "$create_log"
invite="$(sed -n 's/.*INVITE \(splitz:\/\/[^ ]*\).*/\1/p' "$create_log" | head -1)"
if [ -z "$invite" ]; then
  echo "the create phase printed no invite" >&2
  exit 1
fi
echo "invite: $invite"

phase join "$UDID_B" --dart-define="SPLITS_INVITE=$invite"
echo "── the bill device A opened arrived on device B ──"
