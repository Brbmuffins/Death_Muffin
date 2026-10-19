#!/usr/bin/env bash
# Keep the shared checkout at origin/main (timer death-muffin-checkout-sync, nightly 04:55 UTC, before the drift report). Sessions and the Discord agent
# work in worktrees off origin/main and push from there, so nothing else moves this checkout, and a session that opened it read the old game's rules
# (364 commits behind on 2026-10-19). Fast-forward only, and only when it is on main with no uncommitted or untracked changes and no Discord agent
# ship is running; otherwise it says why and changes nothing (the drift report's check 5 keeps saying it is behind).   sync-checkout.sh
set -uo pipefail
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
SHIP_ACTIVE="${SHIP_ACTIVE:-/home/ubuntu/death-muffin/discord-agent/state/ship-active}"
g() { git -C "$REPO" "$@"; }
g fetch -q origin || { echo "sync-checkout: git fetch failed"; exit 1; }
[ "$(g branch --show-current)" = main ] || { echo "sync-checkout: $REPO is not on main; left as it is"; exit 0; }
[ -z "$(g status --porcelain)" ] || { echo "sync-checkout: $REPO has uncommitted changes; left as it is"; exit 0; }
[ ! -e "$SHIP_ACTIVE" ] || { echo "sync-checkout: a Discord agent ship is running; left for the next run"; exit 0; }
behind=$(g rev-list --count HEAD..origin/main)
[ "$behind" -gt 0 ] || { echo "sync-checkout: up to date at $(g rev-parse --short=8 HEAD)"; exit 0; }
g merge -q --ff-only origin/main || { echo "sync-checkout: main has commits origin/main lacks; left as it is"; exit 1; }
echo "sync-checkout: fast-forwarded $behind commit(s) to $(g rev-parse --short=8 HEAD)"
