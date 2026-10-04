#!/usr/bin/env bash
# Install (or update) the runner from a COMMITTED revision into ~/death-muffin/discord-agent (outside every checkout, so the agent
# cannot edit its own rules). Does NOT start anything.   install-runner.sh [rev]
# Env overrides (tests): DEST, REPO, OWNER_ID, NO_SYSTEMD=1
set -euo pipefail
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
DEST="${DEST:-/home/ubuntu/death-muffin/discord-agent}"
REV="${1:-origin/master}"
SRC=server/death-muffin/discord-agent
mkdir -p "$DEST/runner/lib" "$DEST/state"
chmod 700 "$DEST/state"
for f in $(git -C "$REPO" ls-tree -r --name-only "$REV" -- "$SRC/runner" | sed "s#^$SRC/##") ship.sh rollback.sh check.sh regen.sh agit PROMPT.md config.example.json death-muffin-discord-agent.service; do
  mkdir -p "$DEST/$(dirname "$f")"; git -C "$REPO" show "$REV:$SRC/$f" > "$DEST/$f"
done
chmod 755 "$DEST/ship.sh" "$DEST/rollback.sh" "$DEST/check.sh" "$DEST/regen.sh" "$DEST/agit"
if [ ! -f "$DEST/config.json" ]; then
  OWNER="${OWNER_ID:-$(grep -h '^DEVELOPER_USER_ID=' /opt/crossworlds-bot/.env | head -1 | cut -d= -f2 | tr -d '"')}"
  [ -n "$OWNER" ] || { echo "owner id not found; set OWNER_ID" >&2; exit 1; }
  sed "s/__OWNER_DISCORD_ID__/$OWNER/" "$DEST/config.example.json" > "$DEST/config.json"
  echo "wrote $DEST/config.json (owner id filled in; edit it to change people, channel, models)"
fi
if [ ! -f "$DEST/secret" ]; then umask 077; head -c 32 /dev/urandom | base64 | tr -d '=+/\n' > "$DEST/secret"; echo "generated $DEST/secret"; fi
chmod 600 "$DEST/secret" "$DEST/config.json"
mkdir -p /home/ubuntu/death-muffin/deploy
if [ -z "${NO_SYSTEMD:-}" ]; then
  sudo cp "$DEST/death-muffin-discord-agent.service" /etc/systemd/system/death-muffin-discord-agent.service
  sudo systemctl daemon-reload
  echo "installed unit (NOT started). Start with: sudo systemctl enable --now death-muffin-discord-agent"
fi
echo "Next: install-bot.sh (needs sudo) to wire the Discord side, using the same secret."
