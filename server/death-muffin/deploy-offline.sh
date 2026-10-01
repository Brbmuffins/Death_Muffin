#!/bin/bash
set -euo pipefail

SOURCE=${1:-/home/ubuntu/vps-handoffs/DeathMuffin/game}
RUNTIME=/home/ubuntu/death-muffin/backend
PUBLIC=/var/www/death-muffin/offline
LANDING=/var/www/death-muffin/index.html
BACKUP=/home/ubuntu/death-muffin/deploy/backup-pre-offline-$(date -u +%Y%m%dT%H%M%SZ)

test -f "$SOURCE/dist-offline/sw.js"
test -f "$SOURCE/server/death-muffin/backend/offline-sync.cjs"
test -f "$SOURCE/server/death-muffin/site/index.html"
node --check "$SOURCE/server/death-muffin/backend/server.js"
mkdir -p "$BACKUP"
cp -a "$RUNTIME/server.js" "$BACKUP/server.js"
if test -f "$RUNTIME/offline-sync.cjs"; then cp -a "$RUNTIME/offline-sync.cjs" "$BACKUP/offline-sync.cjs"; fi
sudo cp -a "$LANDING" "$BACKUP/landing-index.html"
if test -e "$PUBLIC"; then sudo cp -a "$PUBLIC" "$BACKUP/offline"; fi
cat > "$BACKUP/ROLLBACK.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cp -a '$BACKUP/server.js' '$RUNTIME/server.js'
if test -f '$BACKUP/offline-sync.cjs'; then cp -a '$BACKUP/offline-sync.cjs' '$RUNTIME/offline-sync.cjs'; fi
sudo systemctl restart death-muffin-auth.service
sudo cp -a '$BACKUP/landing-index.html' '$LANDING'
if test -d '$BACKUP/offline'; then sudo cp -a '$BACKUP/offline/.' '$PUBLIC/'; fi
echo 'Previous Death Muffin backend, landing and offline entry files restored.'
EOF
chmod 700 "$BACKUP/ROLLBACK.sh"

if ! cmp -s "$SOURCE/server/death-muffin/backend/offline-sync.cjs" "$RUNTIME/offline-sync.cjs" ||
   ! cmp -s "$SOURCE/server/death-muffin/backend/server.js" "$RUNTIME/server.js"; then
  cp -a "$SOURCE/server/death-muffin/backend/offline-sync.cjs" "$RUNTIME/offline-sync.cjs"
  cp -a "$SOURCE/server/death-muffin/backend/server.js" "$RUNTIME/server.js"
  node --check "$RUNTIME/server.js"
  sudo systemctl restart death-muffin-auth.service
  for attempt in {1..20}; do
    if curl --silent --show-error --fail http://127.0.0.1:5190/health >/dev/null; then break; fi
    sleep 1
  done
  curl --silent --show-error --fail http://127.0.0.1:5190/health >/dev/null
fi

sudo install -d -m 755 "$PUBLIC"
sudo cp -a "$SOURCE/dist-offline/." "$PUBLIC/"
sudo chown -R root:root "$PUBLIC"
sudo chmod -R a+rX "$PUBLIC"
sudo cp -a "$SOURCE/server/death-muffin/site/index.html" "$LANDING"

curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/offline/ -o "$BACKUP/public-index.html"
cmp "$SOURCE/dist-offline/index.html" "$BACKUP/public-index.html"
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/offline/sw.js -o "$BACKUP/public-sw.js"
cmp "$SOURCE/dist-offline/sw.js" "$BACKUP/public-sw.js"
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/ -o "$BACKUP/public-landing-index.html"
cmp "$SOURCE/server/death-muffin/site/index.html" "$BACKUP/public-landing-index.html"
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/api/health
echo
echo "Offline edition published. Backup: $BACKUP"
