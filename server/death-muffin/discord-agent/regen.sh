#!/usr/bin/env bash
# Regenerates the files that are DERIVED from shared game data, so a data change can be committed together with its generated
# server bundles: build:server-rules (server/**/*-rules.cjs), gen:loot (docs/LOOT-TABLES.md) and embed-realtime (the realtime
# deploy script). Same sandbox as check.sh: fresh user/network/mount namespaces, loopback only, home read-only, the worktree
# (and only it) writable. Run from the worktree root. Prints what changed (git status) afterwards.
set -euo pipefail
TOP=$(git rev-parse --show-toplevel)
export TOP
unshare -rnm bash -c '
  set -euo pipefail
  ip link set lo up
  ro() { [ -e "$1" ] && mount --bind "$1" "$1" && mount -o remount,bind,ro "$1" || true; }
  ro /home/ubuntu
  mount --bind "$TOP" "$TOP" && mount -o remount,bind,rw "$TOP"
  cd "$TOP"
  npm run -s build:server-rules
  npm run -s gen:loot
  node tools/embed-realtime.mjs
'
echo "== regenerated; changed files:"
git -C "$TOP" --no-optional-locks status --porcelain
