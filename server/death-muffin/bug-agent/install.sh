#!/usr/bin/env bash
# Install (or update) the daily bug-report agent from a COMMITTED revision: tooling to ~/death-muffin/bug-agent (outside every
# checkout, so the agent cannot edit its own rules), units to systemd, timer enabled.   install.sh [rev]
set -euo pipefail
REPO=/home/ubuntu/vps-handoffs/DeathMuffin/game
STATE=/home/ubuntu/death-muffin/bug-agent
REV="${1:-origin/master}"
mkdir -p "$STATE/runs"
for f in run-bug-agent.sh reports-cli.cjs check.sh agit PROMPT.md; do
  git -C "$REPO" show "$REV:server/death-muffin/bug-agent/$f" > "$STATE/$f"
done
chmod 755 "$STATE/run-bug-agent.sh" "$STATE/check.sh" "$STATE/agit"
mkdir -p /home/ubuntu/.npm /home/ubuntu/.cache
for u in death-muffin-bug-agent.service death-muffin-bug-agent.timer; do
  git -C "$REPO" show "$REV:server/death-muffin/bug-agent/$u" | sudo tee "/etc/systemd/system/$u" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl enable --now death-muffin-bug-agent.timer
systemctl list-timers death-muffin-bug-agent.timer --no-pager
