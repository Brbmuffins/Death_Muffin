#!/usr/bin/env bash
# ExecStop for death-muffin-discord-agent: a stop or restart waits while this runner is shipping (state/ship-active written by
# core.cjs ship()), so a deploy is never killed halfway. Stale files (runner already gone, or another pid) are ignored.
# Usage: wait-for-ship.sh <stateDir> <MAINPID>
F="$1/ship-active"; MAIN="${2:-}"; said=""
for _ in $(seq 1 1800); do                                  # 1800 x 5 s = 150 min, just under TimeoutStopSec
  [ -f "$F" ] || exit 0
  pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$F" 2>/dev/null)
  { [ -n "$pid" ] && [ "$pid" = "$MAIN" ] && kill -0 "$pid" 2>/dev/null; } || exit 0
  [ -n "$said" ] || { echo "wait-for-ship: a ship is running ($(cat "$F")); stop will continue once it finishes"; said=1; }
  sleep 5
done
echo "wait-for-ship: still shipping after 150 min; stopping anyway"
