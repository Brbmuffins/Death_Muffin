#!/usr/bin/env bash
# Install (or update) the runner from a COMMITTED revision into ~/death-muffin/discord-agent (outside every checkout, so the agent
# cannot edit its own rules). Does NOT start anything.   install-runner.sh [rev]
# Env overrides (tests): DEST, REPO, OWNER_ID, NO_SYSTEMD=1
# Also installs art-run.sh / build-art.sh, the trusted art tools (art-tools/) and an empty tripo-budget.json if there is none (the owner edits it),
# and the agent's guides (guides/, the how-tos PROMPT-godot.md names as .dm-guides/<name>.md; runner/lib/guides.cjs copies them into each job).
set -euo pipefail
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
DEST="${DEST:-/home/ubuntu/death-muffin/discord-agent}"
REV="${1:-origin/main}"
SRC=server/death-muffin/discord-agent
# Every guide the core prompt names must be in the revision, or nothing is installed (the runner would refuse every turn).
for n in $(git -C "$REPO" show "$REV:$SRC/PROMPT-godot.md" | grep -o '\.dm-guides/[a-z0-9-]*\.md' | sort -u | sed 's#^\.dm-guides/##'); do
  git -C "$REPO" cat-file -e "$REV:$SRC/guides/$n" 2>/dev/null || { echo "PROMPT-godot.md at $REV names .dm-guides/$n but $SRC/guides/$n is not in that revision; refusing to install" >&2; exit 1; }
done
mkdir -p "$DEST/runner/lib" "$DEST/state"
chmod 700 "$DEST/state"
for f in $(git -C "$REPO" ls-tree -r --name-only "$REV" -- "$SRC/runner" | sed "s#^$SRC/##") ship.sh rollback.sh sandbox-lib.sh check-godot.sh regen-godot.sh shot-godot.sh label-shot.py render-model.sh render-model.py art-run.sh build-art.sh sound-run.mjs build-sound.sh sound-build.mjs build-picture.sh preview-godot.sh agit wait-for-ship.sh reports-cli.cjs PROMPT-godot.md config.example.json death-muffin-discord-agent.service; do
  mkdir -p "$DEST/$(dirname "$f")"; git -C "$REPO" show "$REV:$SRC/$f" > "$DEST/$f"
done
# The guides: the folder is replaced whole, so a guide removed from the repo is gone from the install too.
rm -rf "$DEST/guides.new"; mkdir -p "$DEST/guides.new"
for f in $(git -C "$REPO" ls-tree -r --name-only "$REV" -- "$SRC/guides"); do git -C "$REPO" show "$REV:$f" > "$DEST/guides.new/$(basename "$f")"; done
rm -rf "$DEST/guides"; mv "$DEST/guides.new" "$DEST/guides"
# The retired web game's tools (B57): removed from an install that still has them.
rm -f "$DEST/check.sh" "$DEST/preview.sh" "$DEST/shot.sh" "$DEST/regen.sh" "$DEST/shoot.cjs" "$DEST/PROMPT.md" "$DEST/runner/lib/generated.cjs" "$DEST/runner/lib/numdelta.cjs"
# The game's one setup (tools/check/README.md): the trusted copy the checks, pictures and previews run outside and inside the sandbox.
git -C "$REPO" show "$REV:tools/check/prep.sh" > "$DEST/prep.sh"
# and the CI gate (DECISIONS B59): GitHub CI's verdict on a proposal and on a ship's merged tree
git -C "$REPO" show "$REV:tools/check/ci.sh" > "$DEST/ci.sh"
chmod 755 "$DEST/prep.sh" "$DEST/ci.sh"
chmod 755 "$DEST/ship.sh" "$DEST/rollback.sh" "$DEST/check-godot.sh" "$DEST/regen-godot.sh" "$DEST/shot-godot.sh" "$DEST/label-shot.py" "$DEST/render-model.sh" "$DEST/art-run.sh" "$DEST/build-art.sh" "$DEST/build-sound.sh" "$DEST/build-picture.sh" "$DEST/preview-godot.sh" "$DEST/agit" "$DEST/wait-for-ship.sh"
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
  touch "$(dirname "$DEST")/test-slot.lock"   # the shared "one Godot test run at a time" slot (check-godot.sh)
  sudo systemctl daemon-reload
  echo "installed unit (NOT started). Start with: sudo systemctl enable --now death-muffin-discord-agent"
fi
echo "Next: install-bot.sh (needs sudo) to wire the Discord side, using the same secret."
echo "Then, with the agent restarted and idle: node $DEST/runner/canary.cjs (the practice run, README \"Practice run\"; nothing is posted or shipped)."
