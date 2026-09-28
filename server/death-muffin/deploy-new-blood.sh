#!/usr/bin/env bash
set -euo pipefail

SOURCE=/home/ubuntu/vps-handoffs/DeathMuffin/game
RUNTIME=/home/ubuntu/death-muffin
PUBLIC=/var/www/death-muffin
BACKUP=${1:?Pass the verified pre-release backup directory}

# A production build and a recoverable copy of the live installation must exist.
test -f "$SOURCE/dist/index.html"
test -f "$BACKUP/SHA256SUMS"
(cd "$BACKUP" && sha256sum -c SHA256SUMS >/dev/null)
node --check "$SOURCE/server/death-muffin/backend/server.js"
node --check "$SOURCE/server/death-muffin/backend/discipline.cjs"
node --check "$SOURCE/server/death-muffin/backend/leaderboard.cjs"
node --check "$SOURCE/server/realtime/server.js"

# Publish immutable game files before the entry page so existing tabs can keep
# loading their previous hashed bundles during the release.
sudo cp -a "$SOURCE/dist/assets" "$SOURCE/dist/art" "$SOURCE/dist/models" "$SOURCE/dist/fx" "$PUBLIC/play/"
sudo chmod -R a+rX "$PUBLIC/play/assets" "$PUBLIC/play/art" "$PUBLIC/play/models" "$PUBLIC/play/fx"

# These four runtime files are the complete Death Muffin API/co-op class delta.
# Keep the private .env and all player data in place.
cp "$SOURCE/server/death-muffin/backend/server.js" "$SOURCE/server/death-muffin/backend/discipline.cjs" \
  "$SOURCE/server/death-muffin/backend/leaderboard.cjs" "$RUNTIME/backend/"
cp "$SOURCE/server/realtime/server.js" "$RUNTIME/realtime/server.js"
sudo systemctl restart death-muffin-auth.service death-muffin-realtime.service
sudo systemctl is-active death-muffin-auth.service death-muffin-realtime.service

sudo cp -a "$SOURCE/server/death-muffin/site/leaderboard.js" "$PUBLIC/leaderboard.js"
sudo chmod a+r "$PUBLIC/leaderboard.js"
sudo cp -a "$SOURCE/dist/index.html" "$PUBLIC/play/index.html"
sudo chmod a+r "$PUBLIC/play/index.html"

curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/play/ -o /tmp/death-muffin-new-blood-live.html
cmp /tmp/death-muffin-new-blood-live.html "$SOURCE/dist/index.html"
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/api/health
echo
echo "New Blood release published. Backup: $BACKUP"
