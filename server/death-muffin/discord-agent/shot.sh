#!/usr/bin/env bash
# Screenshots of the agent's branch: shot.sh [scenario.json] (default .dm-shot.json in the worktree; see shoot.cjs for the format).
# Same sandbox as check.sh: fresh user/network/mount namespaces, no network (loopback only), home read-only except the worktree.
# The branch's own Vite dev server runs inside on loopback; headless Chromium loads it with ?offline (no live server involved).
# One browser at a time across all agents (the VPS's software GL is heavy): a shared lock, and a hard time limit.
set -euo pipefail
TOP=$(git rev-parse --show-toplevel)
TOOLS=$(cd "$(dirname "$0")" && pwd)
FILE=${1:-.dm-shot.json}
[ -f "$TOP/$FILE" ] || { echo "no scenario file $FILE in the worktree (see the prompt for the format)"; exit 2; }
NM=$(readlink -f "$TOP/node_modules")
export TOP TOOLS FILE NM
export DM_PLAYWRIGHT_MODULE=${DM_PLAYWRIGHT_MODULE:-/home/ubuntu/.npm/_npx/e41f203b7505f1fb/node_modules/playwright}
export DM_CHROMIUM_PATH=${DM_CHROMIUM_PATH:-/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome}
LOCK=${DM_BROWSER_LOCK:-/home/ubuntu/death-muffin/qa-browser.lock}
exec flock -w 900 "$LOCK" timeout 600 unshare -rnm bash -c '
  set -euo pipefail
  ip link set lo up
  ro() { [ -e "$1" ] && mount --bind "$1" "$1" && mount -o remount,bind,ro "$1" || true; }
  ro /home/ubuntu
  mount --bind "$TOP" "$TOP" && mount -o remount,bind,rw "$TOP"
  mkdir -p "$NM/.vite" 2>/dev/null || true
  mount -t tmpfs tmpfs "$NM/.vite"            # Vite pre-bundles deps here; a scratch copy per run
  export HOME=$(mktemp -d /tmp/dmshot.XXXXXX)  # Chromium profile and caches
  cd "$TOP"
  npx vite --host 127.0.0.1 --port 5188 --strictPort > "$HOME/vite.log" 2>&1 &
  VITE=$!
  for i in $(seq 1 120); do curl -sf -o /dev/null http://127.0.0.1:5188/ && break; sleep 1; done
  DM_SHOT_WT="$TOP" DM_SHOT_FILE="$FILE" DM_SHOT_URL="http://127.0.0.1:5188/?offline" node "$TOOLS/shoot.cjs" || { echo "--- vite log tail"; tail -15 "$HOME/vite.log"; kill $VITE; exit 1; }
  kill $VITE
'
