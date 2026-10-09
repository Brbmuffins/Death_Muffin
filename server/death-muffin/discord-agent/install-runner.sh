#!/usr/bin/env bash
# Install (or update) the runner from a COMMITTED revision into ~/death-muffin/discord-agent (outside every checkout, so the agent
# cannot edit its own rules). Does NOT start anything.   install-runner.sh [rev]
# Env overrides (tests): DEST, REPO, OWNER_ID, NO_SYSTEMD=1
# Also installs art-run.sh / build-art.sh, the trusted art tools (art-tools/) and an empty tripo-budget.json if there is none (the owner edits it).
set -euo pipefail
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
DEST="${DEST:-/home/ubuntu/death-muffin/discord-agent}"
REV="${1:-origin/main}"
SRC=server/death-muffin/discord-agent
mkdir -p "$DEST/runner/lib" "$DEST/state"
chmod 700 "$DEST/state"
for f in $(git -C "$REPO" ls-tree -r --name-only "$REV" -- "$SRC/runner" | sed "s#^$SRC/##") ship.sh rollback.sh sandbox-lib.sh check.sh check-godot.sh regen.sh shot.sh shoot.cjs shot-godot.sh label-shot.py art-run.sh build-art.sh preview.sh preview-godot.sh agit wait-for-ship.sh PROMPT.md PROMPT-godot.md config.example.json death-muffin-discord-agent.service; do
  mkdir -p "$DEST/$(dirname "$f")"; git -C "$REPO" show "$REV:$SRC/$f" > "$DEST/$f"
done
chmod 755 "$DEST/ship.sh" "$DEST/rollback.sh" "$DEST/check.sh" "$DEST/check-godot.sh" "$DEST/regen.sh" "$DEST/shot.sh" "$DEST/shot-godot.sh" "$DEST/label-shot.py" "$DEST/art-run.sh" "$DEST/build-art.sh" "$DEST/preview.sh" "$DEST/preview-godot.sh" "$DEST/agit" "$DEST/wait-for-ship.sh"
# Model generation (Gemini concept -> Tripo): TRUSTED copies of the three tools, run by the runner (art-run.sh) with the API keys, never the ones in a worktree (the agent can edit those).
# They get their own copy of sharp and its dependencies, so nothing the agent can write through a worktree symlink is ever loaded by a process that holds keys.
ART="$DEST/art-tools"; mkdir -p "$ART/tools/ai"
for f in common gemini tripo; do git -C "$REPO" show "$REV:tools/ai/$f.mjs" > "$ART/tools/ai/$f.mjs"; done
grep -q 'DM_ART_ROOT' "$ART/tools/ai/common.mjs" || { echo "tools/ai/common.mjs at $REV has no DM_ART_ROOT support; refusing to install the art tools" >&2; exit 1; }
if [ ! -d "$ART/node_modules/sharp" ] && [ -d "$REPO/node_modules/sharp" ]; then
  mkdir -p "$ART/node_modules"
  for m in sharp detect-libc semver @img; do [ -e "$REPO/node_modules/$m" ] && cp -a "$REPO/node_modules/$m" "$ART/node_modules/"; done
fi
chmod -R go-w "$ART"
if [ ! -f "$DEST/tripo-budget.json" ]; then (umask 077; echo '{}' > "$DEST/tripo-budget.json"); echo "wrote $DEST/tripo-budget.json (empty: nobody may generate models until the owner adds {\"<discord id>\": <credits>})"; fi
chmod 600 "$DEST/tripo-budget.json"
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
