#!/usr/bin/env bash
# Install (or update) the daily bug-report agent from a COMMITTED revision: tooling to ~/death-muffin/bug-agent (outside every
# checkout, so the agent cannot edit its own rules), units to systemd, timer enabled.   install.sh [rev]
set -euo pipefail
REPO=/home/ubuntu/vps-handoffs/DeathMuffin/game
STATE=/home/ubuntu/death-muffin/bug-agent
REV="${1:-origin/main}"
mkdir -p "$STATE/runs"
for f in run-bug-agent.sh reports-cli.cjs PROMPT.md; do
  git -C "$REPO" show "$REV:server/death-muffin/bug-agent/$f" > "$STATE/$f"
done
# One check script, sandbox and agit for both agents (owner, 2026-10-10: the bug agent's copies had drifted and missed the hygiene check and the
# secret hiding): the Discord agent's, installed under the names this agent's prompt uses.
git -C "$REPO" show "$REV:server/death-muffin/discord-agent/check-godot.sh" > "$STATE/check.sh"
for f in sandbox-lib.sh agit; do git -C "$REPO" show "$REV:server/death-muffin/discord-agent/$f" > "$STATE/$f"; done
touch /home/ubuntu/death-muffin/test-slot.lock   # the shared "one Godot test run at a time" slot (check-godot.sh)
chmod 755 "$STATE/run-bug-agent.sh" "$STATE/check.sh" "$STATE/agit"
mkdir -p /home/ubuntu/.npm /home/ubuntu/.cache
for u in death-muffin-bug-agent.service death-muffin-bug-agent.timer; do
  git -C "$REPO" show "$REV:server/death-muffin/bug-agent/$u" | sudo tee "/etc/systemd/system/$u" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl enable --now death-muffin-bug-agent.timer
systemctl list-timers death-muffin-bug-agent.timer --no-pager
