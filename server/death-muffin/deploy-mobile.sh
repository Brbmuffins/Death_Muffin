#!/usr/bin/env bash
# Publish the Death Muffin MOBILE build (phones/tablets) from a COMMITTED revision of the `mobile` branch.
#
#   deploy-mobile.sh [rev]      (default rev: the `mobile` branch tip)
#
# Client only. Served at /death-muffin/mobile/ (static, no nginx change). It ALSO builds and publishes the Offline Edition PWA
# (/death-muffin/offline/) because phones use it and need the touch layer; master's deploy-release.sh no longer touches /offline/. It uses the same API, accounts and co-op
# server as the PC build, so this script NEVER installs server code, runs migrations or restarts services:
# that belongs to master's deploy-release.sh.
#
# 1. Exports <rev> with `git archive`, runs typecheck + client tests, builds `npm run build:death-muffin-mobile` and `npm run build:offline`.
# 2. Backs up the current /var/www/death-muffin/mobile/ (if any) and writes ROLLBACK.sh.
# 3. Publishes hashed assets first, then index.html, then release.txt (open tabs auto-reload when release.txt changes);
#    the offline edition's files first, then its sw.js and index.html.
# 4. Verifies the public page matches the build.
set -euo pipefail

REPO=/home/ubuntu/vps-handoffs/DeathMuffin/game
RUNTIME=/home/ubuntu/death-muffin
PUBLIC=/var/www/death-muffin
URL=https://muffindevelopment.com/death-muffin/mobile
REV="${1:-mobile}"
SHA=$(git -C "$REPO" rev-parse --short=12 "$REV^{commit}")
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
CAND="$RUNTIME/deploy/candidate-mobile-$SHA"
BK="$RUNTIME/deploy/backup-pre-mobile-$SHA-$STAMP"
SRC="$CAND/src"
PREV=$(curl -sf "$URL/release.txt?t=$STAMP" | cut -d" " -f1 || true)

echo "== Building mobile $SHA from git (not the working tree)"
rm -rf "$CAND"
mkdir -p "$SRC"
git -C "$REPO" archive "$SHA" | tar -x -C "$SRC"
ln -s "$REPO/node_modules" "$SRC/node_modules"
[ -d "$REPO/server/realtime/node_modules" ] && ln -s "$REPO/server/realtime/node_modules" "$SRC/server/realtime/node_modules"
(
  cd "$SRC"
  npx tsc --noEmit -p .
  npx vitest run --reporter=dot
  npm run -s build:death-muffin-mobile
  npm run -s build:offline
)
test -f "$SRC/dist-offline/sw.js"
test -f "$SRC/dist/index.html"
grep -q '/death-muffin/mobile/assets/' "$SRC/dist/index.html"
if grep -q '/death-muffin/play/' "$SRC/dist/index.html"; then echo "built index.html still points at /death-muffin/play/"; exit 1; fi

echo "== Backup -> $BK"
mkdir -p "$BK/mobile" "$BK/offline"
if [ -d "$PUBLIC/mobile" ]; then sudo cp -a "$PUBLIC/mobile/." "$BK/mobile/"; fi
sudo cp -a "$PUBLIC/offline/." "$BK/offline/"
cat > "$BK/ROLLBACK.sh" <<EOT
#!/usr/bin/env bash
# Restores the mobile client from before $SHA (if there was none, removes it).
set -euo pipefail
if [ -n "\$(ls -A '$BK/mobile')" ]; then
  sudo cp -a '$BK/mobile/.' '$PUBLIC/mobile/'
else
  sudo rm -rf '$PUBLIC/mobile'
fi
sudo cp -a '$BK/offline/.' '$PUBLIC/offline/'
echo 'Mobile client and offline edition rolled back to before $SHA'
EOT
chmod 700 "$BK/ROLLBACK.sh"

echo "== Publish (assets first, index.html, then release.txt)"
sudo mkdir -p "$PUBLIC/mobile"
for d in assets art models fx audio; do [ -d "$SRC/dist/$d" ] && sudo cp -a "$SRC/dist/$d" "$PUBLIC/mobile/"; done
sudo cp -a "$SRC/dist/precache.html" "$SRC/dist/asset-manifest.json" "$PUBLIC/mobile/" 2>/dev/null || true
sudo cp -a "$SRC/dist/index.html" "$PUBLIC/mobile/index.html"
echo "$SHA $(date -u +%FT%TZ)" > "$CAND/release.txt"
sudo cp "$CAND/release.txt" "$PUBLIC/mobile/release.txt"
(cd "$SRC/dist-offline" && sudo cp -a $(ls -A | grep -vx -e index.html -e sw.js) "$PUBLIC/offline/")
sudo cp -a "$SRC/dist-offline/sw.js" "$SRC/dist-offline/index.html" "$PUBLIC/offline/"
sudo chown -R root:root "$PUBLIC/mobile" "$PUBLIC/offline"
sudo chmod -R a+rX "$PUBLIC/mobile" "$PUBLIC/offline"

echo "== Verify"
curl -sSf "$URL/" | cmp - "$SRC/dist/index.html"
curl -sSf "$URL/release.txt" | grep -q "^$SHA "
curl -sSf https://muffindevelopment.com/death-muffin/offline/ | cmp - "$SRC/dist-offline/index.html"
curl -sSf https://muffindevelopment.com/death-muffin/offline/sw.js | cmp - "$SRC/dist-offline/sw.js"
echo "Mobile $SHA published at $URL/. Rollback: $BK/ROLLBACK.sh"

# Discord notice (optional): the webhook URL lives outside the repo (the repo is public). Never fails the deploy.
HOOK_FILE="$RUNTIME/private/discord-github-webhook.url"
if [ -r "$HOOK_FILE" ]; then
  RANGE="$SHA"; [ -n "$PREV" ] && git -C "$REPO" cat-file -e "$PREV^{commit}" 2>/dev/null && RANGE="$PREV..$SHA"
  git -C "$REPO" log --no-merges --format='%s' -n 12 $RANGE | python3 -c '
import json, sys, urllib.request
sha, prev, url = sys.argv[1], sys.argv[2], open(sys.argv[3]).read().strip()
lines = [l.strip() for l in sys.stdin if l.strip()]
body = "\n".join("• " + l[:150] for l in lines) or "• (no new commits)"
compare = f"https://github.com/Brbmuffins/Death_Muffin/compare/{prev}...{sha}" if prev else f"https://github.com/Brbmuffins/Death_Muffin/commit/{sha}"
embed = {"title": f"Death Muffin mobile {sha[:7]} is live", "url": "https://muffindevelopment.com/death-muffin/mobile/",
         "description": body[:3800] + f"\n\n[What changed]({compare})", "color": 0x7C3AED}
req = urllib.request.Request(url, data=json.dumps({"username": "Death Muffin", "embeds": [embed]}).encode(),
                             headers={"Content-Type": "application/json", "User-Agent": "death-muffin-deploy"})
urllib.request.urlopen(req, timeout=10)
' "$SHA" "${PREV:-}" "$HOOK_FILE" && echo "Discord: mobile notice sent" || echo "Discord: notice failed (deploy is fine)"
fi
