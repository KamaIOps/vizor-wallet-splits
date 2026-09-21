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
  return 0
}
trap cleanup EXIT

device() {
  local name="$1" udid="$2"
  shift 2
  xcrun simctl boot "$udid" 2>/dev/null || true
  wipe_device "$udid"
  (
    set -m
    set +e
    (cd "$root" && fvm flutter test integration_test/splits_ui_settle_test.dart \
      -d "$udid" \
      --dart-define=VIZOR_FORM_FACTOR=mobile \
      --dart-define=ZCASH_DEFAULT_NETWORK=regtest \
      --dart-define=ZCASH_E2E_NETWORK=regtest \
      --dart-define=SPLITS_PHASE="$name" \
      --dart-define=SPLITS_LANE="$lane" \
      --dart-define=SPLITS_RELAY_URL="$relay" \
      "$@") >"$work/$name.log" 2>&1
    echo $? >"$work/$name.status"
  ) &
}

echo "── payer on $UDID_A ─────────────────────────────"
device payer "$UDID_A"
a_pid=$!

# The payer takes the invite off its own share screen. Device B starts only
# once that line exists, which is also what keeps the two builds apart:
# `--dart-define` is compiled in and both runs build into the one `build/`
# directory, so two builds at once leave both devices running the last one.
invite=""
for _ in $(seq 1800); do
  invite="$(sed -n 's/.*BILLCODE \(splitz1:[^ ]*\).*/\1/p' "$work/payer.log" 2>/dev/null | head -1)"
  [ -n "$invite" ] && break
  if [ -f "$work/payer.status" ]; then
    echo "the payer exited before showing a bill code" >&2
    tail -50 "$work/payer.log" >&2
    exit 1
  fi
  sleep 1
done
if [ -z "$invite" ]; then
  echo "the payer never showed a bill code" >&2
  tail -50 "$work/payer.log" >&2
  exit 1
fi
echo "invite: $invite"

echo "── payee on $UDID_B ─────────────────────────────"
device payee "$UDID_B" --dart-define="SPLITS_INVITE=$invite"
b_pid=$!

wait "$a_pid" "$b_pid" 2>/dev/null || true

failed=0
for name in payer payee; do
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
