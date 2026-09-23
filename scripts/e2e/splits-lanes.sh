#!/usr/bin/env bash
# One bill, four devices, and §9.2's three payout lanes at once.
#
# The payer owes three people who want paying three different ways: shielded
# ZEC, USDC on Base, and cash. Only the first can go in a ZIP 321 request, so
# one transaction settles one debt on a regtest chain and the other two are
# recorded and vouched for by the people paid.
#
#   scripts/e2e/splits-lanes.sh
#
# Needs four simulators, Docker for the regtest chain, and the relay from the
# protocol tree. The payer's address is read out of its own output and funded
# before the bill is opened; nothing else needs coins.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so a frozen copy can be run from anywhere. Bash reads a script
# incrementally from a file offset, so editing this file while a run is in
# flight corrupts that run — copy it, set VIZOR_ROOT, and run the copy.
root="${VIZOR_ROOT:-$(cd "$here/../.." && pwd)}"
protocol="${SPLITZ_PROTOCOL:-$HOME/Splitz-Protocol}"
fund="${SPLITS_FUND_ZEC:-1.0}"

. "$here/splits-devices.sh"
trap splits_release_devices EXIT

# Labels for the four log files. The role each device actually
# plays is claimed from the coordinator, in whatever order they
# get there, so a log named `zec` may hold the payer.
declare -a PHASES=(one two three four)
splits_select_devices 4
declare -a UDIDS=("${SPLITS_DEVICES[@]}")

if ! docker ps --format '{{.Names}}' | grep -q lightwalletd; then
  echo "the regtest chain is not up: scripts/regtest/up.sh" >&2
  exit 2
fi

# One coordinator beside the relay. It hands out the roles the devices used to
# be compiled with, and carries the payer's address and invite, so every device
# is launched with identical defines — one build, and they start together.
coord_port="${SPLITS_COORD_PORT:-39400}"
coordinator="http://127.0.0.1:$coord_port"
python3 "$root/scripts/e2e/splits-coordinator.py" --port "$coord_port" \
  --roles payer,zec,usdc,cash &
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

work="$(mktemp -d)"
declare -a PIDS=()

# Killing the wrapper does not kill the work: `fvm flutter test` spawns a dart
# VM and a frontend server that outlive it and get reparented. Each device runs
# in its own process group so the group can be killed, and the group is what is
# signalled.
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true; done
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
    (cd "$root" && fvm flutter test integration_test/splits_lanes_test.dart \
      -d "$udid" \
      --dart-define=VIZOR_FORM_FACTOR=mobile \
      --dart-define=ZCASH_DEFAULT_NETWORK=regtest \
      --dart-define=ZCASH_E2E_NETWORK=regtest \
      --dart-define=SPLITS_COORDINATOR="$coordinator" \
      --dart-define=SPLITS_RELAY_URL="$relay" \
      "$@") >"$work/$name.log" 2>&1
    echo $? >"$work/$name.status"
  ) &
  PIDS+=($!)
  set +m
}

# Waits for a device's app to be up on its simulator.
#
# `--dart-define` is compiled in, and every run builds into the one `build/`
# directory this project has. Two builds at once therefore produce one binary,
# and both devices run whichever finished last — which reads as three payees
# all in the same payout lane. A device is only started once the one before it
# is running, so each binary is built, installed and launched on its own.
await_running() {
  local name="$1" seconds="$2"
  for _ in $(seq "$seconds"); do
    grep -q 'creating wallet' "$work/$name.log" 2>/dev/null && return 0
    if [ -f "$work/$name.status" ]; then
      echo "device $name exited before its app started" >&2
      tail -40 "$work/$name.log" >&2
      return 1
    fi
    sleep 1
  done
  echo "device $name never started its app" >&2
  tail -40 "$work/$name.log" >&2
  return 1
}

# Waits for a line to appear in a device's log, failing if it exits first.
await_line() {
  local name="$1" pattern="$2" seconds="$3" found=""
  for _ in $(seq "$seconds"); do
    found="$(sed -n "s/.*$pattern.*/\1/p" "$work/$name.log" 2>/dev/null | head -1)"
    [ -n "$found" ] && { echo "$found"; return 0; }
    if [ -f "$work/$name.status" ]; then
      echo "device $name exited before printing $pattern" >&2
      tail -40 "$work/$name.log" >&2
      return 1
    fi
    sleep 1
  done
  echo "device $name never printed $pattern" >&2
  tail -40 "$work/$name.log" >&2
  return 1
}

# Every device is launched with the same defines, so one build serves all
# four. Which device each one is, and the payer's address and invite, come
# from the coordinator at runtime.
# Each device starts once the one before it is running. `flutter test` still
# runs the platform build for every device — Gradle on Android does real work
# each time — and two of them writing the one `build/` directory at once fail
# on each other's intermediates.
echo "── device on ${UDIDS[0]} (builds) ───────────────"
device "${PHASES[0]}" "${UDIDS[0]}"
await_running "${PHASES[0]}" 1800
for i in 1 2 3; do
  echo "── device on ${UDIDS[$i]} ───────────────────────"
  device "${PHASES[$i]}" "${UDIDS[$i]}"
  await_running "${PHASES[$i]}" 1800
done

# Whichever device claimed `payer` publishes its address. Only it needs coins.
address=""
for _ in $(seq 1800); do
  address="$(curl -sf "$coordinator/kv/address" || true)"
  [ -n "$address" ] && break
  sleep 1
done
if [ -z "$address" ]; then
  echo "no device published an address" >&2
  for name in "${PHASES[@]}"; do tail -30 "$work/$name.log" 2>/dev/null; done
  exit 1
fi
echo "funding $address with $fund"
"$root/scripts/regtest/fund-wallet.sh" "$address" "$fund"

wait "${PIDS[@]}" 2>/dev/null || true

failed=0
for name in "${PHASES[@]}"; do
  code="$(cat "$work/$name.status" 2>/dev/null || echo 1)"
  echo "── $name (exit $code) ───────────────────────────"
  cat "$work/$name.log"
  [ "$code" != 0 ] && failed=1
done

if [ "$failed" != 0 ]; then
  echo "one or more devices failed" >&2
  exit 1
fi
echo "── one bill: zec on chain, usdc by swap, cash by hand, all vouched for ──"
