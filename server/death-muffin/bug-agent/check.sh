#!/usr/bin/env bash
# The bug-report agent's only way to run code: typecheck + client tests + server tests. Runs in fresh user/network/mount
# namespaces: no network, and everything the agent must not be able to change (home config, the repo's .git, the agent's own
# tooling, the live runtime) is remounted read-only, so test code it writes cannot phone out or plant anything.
# Run from the worktree root (the agent's cwd).
set -euo pipefail
TOP=$(git rev-parse --show-toplevel)
COMMON=$(cd "$TOP" && git rev-parse --path-format=absolute --git-common-dir)
export TOP COMMON
exec unshare -rnm bash -c '
  set -euo pipefail
  ip link set lo up   # loopback only (the realtime tests listen on 127.0.0.1); nothing routes out
  ro() { [ -e "$1" ] && mount --bind "$1" "$1" && mount -o remount,bind,ro "$1" || true; }
  ro /home/ubuntu
  # Re-open only the worktree for writing (vitest/tsc caches live in node_modules -> read-only is fine; they fall back).
  mount --bind "$TOP" "$TOP" && mount -o remount,bind,rw "$TOP"
  cd "$TOP"
  npx tsc --noEmit -p .
  npx vitest run --reporter=dot --no-cache
  npm run -s test:server > /tmp/bug-agent-server-tests.$$ 2>&1 || { tail -40 /tmp/bug-agent-server-tests.$$; exit 1; }
  grep -E "^# (tests|pass|fail)" /tmp/bug-agent-server-tests.$$
'
