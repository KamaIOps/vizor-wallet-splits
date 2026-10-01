#!/usr/bin/env bash
# Whether the protocol tree pubspec.yaml links (../Splitz-Protocol) is the one
# splitz-protocol.rev pins, with nothing uncommitted in it.
#
# The wallet reaches the protocol by path, so a build links whatever that
# directory holds and nothing in pubspec.lock or the build records it. CI
# checks out the pinned commit; run this before any other build that ships.
#
# Exit 0 and print the commit when it is the pin and clean; exit 1 and say
# which part differs otherwise. SPLITZ_PROTOCOL_DIR names another tree.
set -euo pipefail

wallet="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
protocol="${SPLITZ_PROTOCOL_DIR:-$wallet/../Splitz-Protocol}"
pin="$(tr -d '[:space:]' < "$wallet/splitz-protocol.rev")"

if ! head="$(git -C "$protocol" rev-parse HEAD 2>/dev/null)"; then
  echo "no protocol checkout at $protocol" >&2
  exit 1
fi

status=0
if [[ "$head" != "$pin" ]]; then
  echo "protocol is at $head; splitz-protocol.rev pins $pin" >&2
  status=1
fi
# Only what the wallet links: the two packages pubspec.yaml names.
dirty="$(git -C "$protocol" status --porcelain -- dart splitz_host | wc -l | tr -d ' ')"
if [[ "$dirty" != "0" ]]; then
  echo "protocol has $dirty uncommitted path(s) under dart/ or splitz_host/" >&2
  status=1
fi
if [[ "$status" == "0" ]]; then
  echo "$head"
fi
exit "$status"
