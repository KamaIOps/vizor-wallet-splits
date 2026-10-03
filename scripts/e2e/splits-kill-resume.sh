#!/usr/bin/env bash
# The app killed in the middle of paying a bill, then relaunched — regtest.
#
#   SPLITS_UDID_A=<simulator> scripts/e2e/splits-kill-resume.sh
#
# Phase one funds a fresh wallet, opens a bill owing a payee 0.01 ZEC and logs
# KILLPOINT as it starts the send; this script kills the app's process the
# moment that line appears (KILL_DELAY seconds later, default 0). Phase two
# relaunches the same install, which must find the unresolved send, refuse a
# second one, and resolve it from the wallet's history. Passes when the node
# says the payee received exactly 0.01 ZEC — once, whichever instant the kill
# landed at — and the lane itself exits 0.
#
# HOLD_BROADCAST=1 makes the instant exact: the app reaches lightwalletd
# through scripts/e2e/lwd-hold-proxy.py, which holds back the transaction's
# upload, and the app is killed once the proxy reports it held. The wallet has
# built and stored the transaction and the node has never seen it — the
# outcome a guessed delay lands on only by luck. The lane then also requires
# the node's mempool to be empty at the kill.
#
# HOLD_BROADCAST=expire holds it the same way, then keeps it from the node
# after the relaunch too: every rebroadcast is dropped while blocks are mined,
# so the transaction expires unmined. The relaunched app must then clear the
# note and send the debt again, and the lane requires that branch. The test
# switches the proxy back to relaying before that second send.
#
# Needs Docker with scripts/regtest/up.sh already run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${VIZOR_ROOT:-$(cd "$here/../.." && pwd)}"
. "$root/scripts/regtest/lib.sh"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.keplr.vizor}"
UDID="${SPLITS_UDID_A:?a simulator udid}"
delay="${KILL_DELAY:-0}"
hold="${HOLD_BROADCAST:-0}"
case "$hold" in 0 | 1 | expire) ;; *) echo "HOLD_BROADCAST is 0, 1 or expire" >&2; exit 1 ;; esac
proxy_port="${HOLD_PROXY_PORT:-19077}"
work="${SPLITS_WORK:-$(mktemp -d)}"
mkdir -p "$work"
find "$work" -maxdepth 1 -type f \( -name 'phase-*.log' -o -name '*.status' \) -delete
echo "logs: $work"

wait_for_zcashd
payee="$(zcash_cli z_getnewaddress sapling)"
echo "payee: $payee"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl terminate "$UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl keychain "$UDID" reset >/dev/null 2>&1 || true

pid=""
miner=""
proxy=""
cleanup() {
  [ -n "$miner" ] && kill "$miner" 2>/dev/null || true
  [ -n "$proxy" ] && kill "$proxy" 2>/dev/null || true
  [ -n "$pid" ] && { kill -- "-$pid" 2>/dev/null || true; }
  # The script's own status, not this trap's last test, is the exit code.
  return 0
}
trap cleanup EXIT

lwd_define=()
resume_define=()
if [ "$hold" != 0 ]; then
  echo relay >"$work/proxy.mode"
  python3 "$here/lwd-hold-proxy.py" "$proxy_port" 9067 "$work/proxy.mode" >"$work/proxy.log" 2>&1 &
  proxy=$!
  lwd_define=(--dart-define=ZCASH_E2E_LIGHTWALLETD_URL="http://127.0.0.1:$proxy_port")
fi

phase() {
  local name="$1"
  set -m
  (
    set +e
    (cd "$root" && fvm flutter test integration_test/splits_kill_resume_test.dart \
      -d "$UDID" --no-uninstall \
      --dart-define=VIZOR_FORM_FACTOR=mobile \
      --dart-define=ZCASH_DEFAULT_NETWORK=regtest \
      --dart-define=ZCASH_E2E_NETWORK=regtest \
      --dart-define=SPLITS_PHASE="$name" \
      --dart-define=SPLITS_PAYEE_ADDRESS="$payee" ${lwd_define[@]+"${lwd_define[@]}"} \
      ${resume_define[@]+"${resume_define[@]}"}) >"$work/phase-$name.log" 2>&1
    echo $? >"$work/$name.status"
  ) &
  pid=$!
  set +m
}

# The app's own process on this simulator, not the flutter tool driving it.
app_pid() {
  ps -ax -o pid=,command= | grep "Devices/$UDID/data/Containers/Bundle/Application/.*/Runner.app/Runner" |
    grep -v grep | awk '{print $1}' | head -1
}

# ── phase one: fund, start the send, kill ──────────────────────────────
phase send
address=""
for _ in $(seq 1800); do
  address="$(sed -n 's/.*ADDRESS \([^[:space:]]*\).*/\1/p' "$work/phase-send.log" | head -1)"
  [ -n "$address" ] && break
  [ -f "$work/send.status" ] && { tail -40 "$work/phase-send.log"; exit 1; }
  sleep 1
done
echo "funding $address"
"$root/scripts/regtest/fund-wallet.sh" "$address" 1.0 >/dev/null

for _ in $(seq 900); do
  grep -q KILLPOINT "$work/phase-send.log" && break
  [ -f "$work/send.status" ] && { tail -40 "$work/phase-send.log"; exit 1; }
  sleep 0.2
done
grep -q KILLPOINT "$work/phase-send.log" || { echo "no KILLPOINT" >&2; exit 1; }
if [ "$hold" != 0 ]; then
  # Armed only now: funding and the sync before it relay untouched.
  echo hold >"$work/proxy.mode"
  for _ in $(seq 600); do
    grep -q HELD "$work/proxy.log" && break
    [ -f "$work/send.status" ] && { tail -40 "$work/phase-send.log"; exit 1; }
    sleep 0.2
  done
  grep HELD "$work/proxy.log" || { echo "the proxy held nothing" >&2; exit 1; }
else
  sleep "$delay"
fi
victim="$(app_pid)"
[ -n "$victim" ] || { echo "no app process found to kill" >&2; exit 1; }
kill -9 "$victim"
echo "killed the app (pid $victim) $(date +%T)"
grep -q "SETTLED" "$work/phase-send.log" && echo "note: the send had already finished"
if [ "$hold" != 0 ]; then
  mempool="$(zcash_cli getrawmempool | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  echo "node mempool at the kill: $mempool"
  [ "$mempool" = 0 ] || { echo "── the transaction reached the node before the kill ──" >&2; exit 1; }
  grep -q SETTLED "$work/phase-send.log" && { echo "── the send finished before the kill ──" >&2; exit 1; }
  if [ "$hold" = expire ]; then
    echo drop >"$work/proxy.mode"
    resume_define=(--dart-define=SPLITS_PROXY_MODE_FILE="$work/proxy.mode"
      --dart-define=SPLITS_EXPECT_EXPIRY=true)
  else
    echo relay >"$work/proxy.mode"
  fi
fi
sleep 3
kill -- "-$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
pid=""

# ── phase two: relaunch the same install ───────────────────────────────
( while true; do "$root/scripts/regtest/mine.sh" 1 >/dev/null 2>&1; sleep 5; done ) &
miner=$!
phase resume
wait "$pid" 2>/dev/null || true
pid=""
kill "$miner" 2>/dev/null || true
miner=""
"$root/scripts/regtest/mine.sh" 3 >/dev/null 2>&1 || true
code="$(cat "$work/resume.status" 2>/dev/null || echo 1)"
grep -E "PENDING|second send|claim nothing|BRANCH|history:|DONE|Expected|Actual|Which" "$work/phase-resume.log" | tail -20

# z_getbalance is disabled on this zcashd; read the notes the address holds.
# Exactly one: the debt is 10.00 USD, and its zatoshi follow the bill's rate,
# which the organiser's device may have re-priced from the feed on relaunch.
# A note in a block mined seconds ago may not be listed yet, so the notes are
# read for 30 seconds rather than once; two notes end the wait early.
for _ in $(seq 30); do
  notes="$(zcash_cli z_listreceivedbyaddress "$payee" 0 |
    python3 -c 'import json,sys; r=json.load(sys.stdin); print(len(r), sum(n["amount"] for n in r))')"
  [ "${notes%% *}" -ge 2 ] && break
  sleep 1
done
count="${notes%% *}"
received="${notes#* }"
echo "payee received: $count note(s), $received ZEC (expected exactly one)"
if [ "$code" != 0 ]; then
  echo "── the resume phase FAILED (exit $code) ──" >&2
  exit 1
fi
if [ "$count" != 1 ]; then
  echo "── the payee was not paid exactly once ──" >&2
  exit 1
fi
if [ "$hold" = expire ]; then
  dropped="$(grep -c DROPPED "$work/proxy.log" || true)"
  echo "rebroadcasts dropped: $dropped"
  grep -q "BRANCH killed-before-broadcast" "$work/phase-resume.log" ||
    { echo "── the held send did not expire and get sent again ──" >&2; exit 1; }
fi
echo "── killed mid-send, relaunched, paid exactly once ──"
