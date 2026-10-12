#!/usr/bin/env bash
# Wire the Discord side into /opt/muffin (user `muffin`): dm-agent.js adapter + patched bot.js + dm-agent.env (shared secret).
# Refuses if /opt/muffin/discord/bot.js is not the version this patch was made against. Backs up the old bot.js. Does NOT restart anything.
# Adapter only: a bot.js that already loads ./dm-agent but carries other hooks too (the Hammy Xchange agent patches the same file, from its own
# repo) is left alone; only dm-agent.js and dm-agent.env are updated (backup of the old adapter kept), so adapter fixes still install.
#   install-bot.sh [rev]        Env overrides (tests): MUFFIN=/opt/muffin, DEST secret file, NO_CHOWN=1
set -euo pipefail
REPO="${REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}"
REV="${1:-origin/main}"
MUFFIN="${MUFFIN:-/opt/muffin}"
SECRET_FILE="${SECRET_FILE:-/home/ubuntu/death-muffin/discord-agent/secret}"
SRC=server/death-muffin/discord-agent/bot
SUDO="sudo"; [ -n "${NO_CHOWN:-}" ] && SUDO=""
WANT=$(git -C "$REPO" show "$REV:$SRC/ORIGINAL_BOT_SHA256" | tr -d '[:space:]')
HAVE=$(sha256sum "$MUFFIN/discord/bot.js" | cut -d' ' -f1)
PATCHED=$(git -C "$REPO" show "$REV:$SRC/bot.cjs" | sha256sum | cut -d' ' -f1)
ADAPTER_ONLY=""
if [ "$HAVE" != "$WANT" ] && [ "$HAVE" != "$PATCHED" ]; then
  if grep -q "require('./dm-agent')" "$MUFFIN/discord/bot.js"; then ADAPTER_ONLY=1; echo "bot.js already loads ./dm-agent and has other hooks too: leaving it alone, updating the adapter only"
  else echo "bot.js differs from the version this patch targets; merge by hand (diff in $SRC/)" >&2; exit 1; fi
fi
[ -f "$SECRET_FILE" ] || { echo "run install-runner.sh first (no secret at $SECRET_FILE)" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git -C "$REPO" show "$REV:$SRC/bot.cjs" > "$TMP/bot.cjs"
git -C "$REPO" show "$REV:$SRC/dm-agent.cjs" > "$TMP/dm-agent.cjs"
node --check "$TMP/bot.cjs"; node --check "$TMP/dm-agent.cjs"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
if [ -z "$ADAPTER_ONLY" ]; then
  [ "$HAVE" = "$WANT" ] && $SUDO cp -a "$MUFFIN/discord/bot.js" "$MUFFIN/discord/bot.js.bak-$STAMP"
  $SUDO install -m 644 "$TMP/bot.cjs" "$MUFFIN/discord/bot.js"
fi
[ -f "$MUFFIN/discord/dm-agent.js" ] && $SUDO cp -a "$MUFFIN/discord/dm-agent.js" "$MUFFIN/discord/dm-agent.js.bak-$STAMP"
$SUDO install -m 644 "$TMP/dm-agent.cjs" "$MUFFIN/discord/dm-agent.js"
printf 'DM_AGENT_SECRET=%s\nDM_AGENT_URL=http://127.0.0.1:%s\n' "$(cat "$SECRET_FILE")" "${RUNNER_PORT:-4321}" > "$TMP/dm-agent.env"
$SUDO install -m 600 "$TMP/dm-agent.env" "$MUFFIN/dm-agent.env"
[ -z "${NO_CHOWN:-}" ] && sudo chown muffin:muffin "$MUFFIN/discord/bot.js" "$MUFFIN/discord/dm-agent.js" "$MUFFIN/dm-agent.env"
echo "installed. Start the runner first, then: sudo systemctl restart muffin-discord"
echo "(muffin-discord.service has ReadWritePaths=/opt/muffin and reaches 127.0.0.1; no unit change needed)"
