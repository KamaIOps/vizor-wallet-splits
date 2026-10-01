#!/usr/bin/env bash
# Settling a debt a payment request cannot carry — through the screens, on two
# devices.
#
#   LANE=cash   the payee takes cash; the payer records it and the payee
#               vouches for it, both from the screens
#   LANE=swap   the payee takes USDC on Base; the payer reaches the swap
#               screen, which quotes against a provider
#
#   scripts/e2e/splits-ui-settle.sh
#
# Needs two simulators and the relay from the protocol tree.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so a frozen copy can be run from anywhere. Bash reads a script
# incrementally from a file offset, so editing this file while a run is in
# flight corrupts that run — copy it, set VIZOR_ROOT, and run the copy.
root="${VIZOR_ROOT:-$(cd "$here/../.." && pwd)}"
protocol="${SPLITZ_PROTOCOL:-$HOME/Splitz-Protocol}"
lane="${LANE:-cash}"

. "$here/splits-devices.sh"
trap splits_release_devices EXIT
splits_select_devices 2
UDID_A="${SPLITS_DEVICES[0]}"
UDID_B="${SPLITS_DEVICES[1]}"

# One coordinator beside the relay. It hands out the roles the devices used to
# be compiled with, and carries the bill code the payee joins by, so both are
# launched with identical defines — one build, and they start together.
coord_port="${SPLITS_COORD_PORT:-39400}"
coordinator="http://127.0.0.1:$coord_port"
python3 "$root/scripts/e2e/splits-coordinator.py" --port "$coord_port" \
  --roles payer,payee &
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
echo "relay: $relay  lane: $lane"

work="$(mktemp -d)"
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
  splits_release_devices
}
trap cleanup EXIT

device() {
  local name="$1" udid="$2"
  shift 2
  splits_prepare_device "$udid" "${relay##*:}" "$coord_port" 9067
  # Monitor mode puts the job in a process group of its own, whose id is
  # its pid, so cleanup can kill the VM `flutter test` leaves behind.
  set -m
  (
    set +e
    (cd "$root" && fvm flutter test integration_test/splits_ui_settle_test.dart \
      -d "$udid" \
      --dart-define=VIZOR_FORM_FACTOR=mobile \
      --dart-define=ZCASH_DEFAULT_NETWORK=regtest \
      --dart-define=ZCASH_E2E_NETWORK=regtest \
      --dart-define=SPLITS_COORDINATOR="$coordinator" \
      --dart-define=SPLITS_LANE="$lane" \
      --dart-define=SPLITS_RELAY_URL="$relay" \
      "$@") >"$work/$name.log" 2>&1
    echo $? >"$work/$name.status"
  ) &
  set +m
}

# Waits for a device's app to be up on its simulator.
#
# Both devices are launched with the same defines and so are one binary, but
# four processes writing this project's single `build/` directory can still
# corrupt each other's artifacts. The second device starts once the first is
# running, which costs one build instead of two.
await_running() {
  local name="$1" seconds="$2"
  for _ in $(seq "$seconds"); do
    grep -q 'creating wallet' "$work/$name.log" 2>/dev/null && return 0
    if [ -f "$work/$name.status" ]; then
      echo "device $name exited before its app started" >&2
      tail -50 "$work/$name.log" >&2
      return 1
    fi
    sleep 1
  done
  echo "device $name never started its app" >&2
  tail -50 "$work/$name.log" >&2
  return 1
}

echo "── device on $UDID_A (builds) ───────────────────"
device one "$UDID_A"
a_pid=$!
await_running one 1800

echo "── device on $UDID_B ────────────────────────────"
device two "$UDID_B"
b_pid=$!

wait "$a_pid" "$b_pid" 2>/dev/null || true

failed=0
for name in one two; do
  code="$(cat "$work/$name.status" 2>/dev/null || echo 1)"
  echo "── $name (exit $code) ───────────────────────────"
  cat "$work/$name.log"
  [ "$code" != 0 ] && failed=1
done

if [ "$failed" != 0 ]; then
  echo "one or both devices failed" >&2
  exit 1
fi
echo "── settled apart in the $lane lane, through the screens ──"
