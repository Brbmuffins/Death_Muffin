#!/usr/bin/env bash
# Git pre-push hook for the shared Death Muffin checkout (installed as <git-common-dir>/hooks/pre-push by server/death-muffin/ops/install.sh).
# Refuses a push to main while a Discord agent ship is running (owner, 2026-10-10): main moving mid-ship stops that ship ("master-moved",
# nothing pushed) and its approver has to react ✅ again. Branch pushes are never blocked. The agent's own ship, its runner and agit run git
# with hooks off (core.hooksPath=/dev/null), so this hook never blocks them. Override once with DM_ALLOW_PUSH_DURING_SHIP=1.
SHIP_ACTIVE="${DM_SHIP_ACTIVE_FILE:-/home/ubuntu/death-muffin/discord-agent/state/ship-active}"
[ -n "${DM_ALLOW_PUSH_DURING_SHIP:-}" ] && exit 0
while read -r _lref _lsha rref _rsha; do
  [ "$rref" = "refs/heads/main" ] || continue
  if [ -e "$SHIP_ACTIVE" ]; then
    echo "pre-push: a Discord agent ship is running ($(cat "$SHIP_ACTIVE" 2>/dev/null | head -c 200)); pushing main now would stop it." >&2
    echo "pre-push: wait for it to finish (the file $SHIP_ACTIVE goes away), then pull/rebase and push. Override: DM_ALLOW_PUSH_DURING_SHIP=1" >&2
    exit 1
  fi
done
exit 0
