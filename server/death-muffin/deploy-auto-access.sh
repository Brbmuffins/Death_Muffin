#!/usr/bin/env bash
# Publish the account-specific Medium default and Brbmuffins Auto Combat gate.
# Usage: deploy-auto-access.sh <frozen candidate containing dist/ and backend/server.js>
set -euo pipefail
umask 077

SRC="${1:?pass the frozen release candidate directory}"
RUNTIME=/home/ubuntu/death-muffin
PUBLIC=/var/www/death-muffin/play
BACKUP="$RUNTIME/deploy/backup-pre-auto-access-$(date -u +%Y%m%dT%H%M%SZ)"
test -f "$SRC/dist/index.html"
test -f "$SRC/backend/server.js"
node --check "$SRC/backend/server.js"
mkdir -p "$BACKUP"
cp -a "$RUNTIME/backend/server.js" "$BACKUP/server.js"
sudo cp -a "$PUBLIC/index.html" "$BACKUP/index.html"
sha256sum "$BACKUP/server.js" "$BACKUP/index.html" > "$BACKUP/SHA256SUMS"

cat > "$BACKUP/ROLLBACK.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cp -a '$BACKUP/server.js' '$RUNTIME/backend/server.js'
sudo systemctl restart death-muffin-auth.service
sudo cp -a '$BACKUP/index.html' '$PUBLIC/index.html'
echo 'Death Muffin backend and index restored; previously published assets retained.'
EOF
chmod 700 "$BACKUP/ROLLBACK.sh"

cp -a "$SRC/backend/server.js" "$RUNTIME/backend/server.js"
sudo systemctl restart death-muffin-auth.service
sudo systemctl is-active death-muffin-auth.service
curl --silent --show-error --fail --retry 8 --retry-delay 1 --retry-all-errors https://muffindevelopment.com/death-muffin/api/health

# Old hashed bundles remain available to tabs that were already open.
sudo cp -a "$SRC/dist/assets" "$PUBLIC/"
sudo cp -a "$SRC/dist/index.html" "$PUBLIC/index.html"
sudo chown -R root:root "$PUBLIC"
sudo chmod -R a+rX "$PUBLIC"
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/play/ -o "$BACKUP/live-index.html"
cmp "$BACKUP/live-index.html" "$SRC/dist/index.html"
echo "Death Muffin Auto Combat release published. Rollback: $BACKUP/ROLLBACK.sh"
