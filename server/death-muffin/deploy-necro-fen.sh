#!/usr/bin/env bash
# Publish the integrated necromancer weapons, alchemy reagents and Mourning Fen release.
# Usage: deploy-necro-fen.sh <frozen release candidate directory>
# The candidate must contain dist/ and the versioned server/ files from one build.
set -euo pipefail

SRC="${1:?pass the frozen release candidate directory}"
RUNTIME=/home/ubuntu/death-muffin
PUBLIC=/var/www/death-muffin/play
BK="$RUNTIME/deploy/backup-pre-necro-fen-$(date -u +%Y%m%dT%H%M%SZ)"
test -f "$SRC/dist/index.html"
for n in 013-necro-weapons 014-alchemy-reagents 015-fen; do
  test -f "$SRC/server/death-muffin/backend/migrations/$n.sql"
done
node --check "$SRC/server/death-muffin/backend/chronicle.cjs"
node --check "$SRC/server/realtime/server.js"
node --check "$SRC/server/vps-handoff/necro-progress/necro-rules.cjs"
for f in "$SRC"/server/death-muffin/backend/gathering/*.cjs; do node --check "$f"; done

mkdir -p "$BK/backend/gathering" "$BK/backend/necro-progress" "$BK/realtime" "$BK/play"
# A database dump is for disaster recovery. Normal code rollback keeps newer player data.
sudo mysqldump --single-transaction death_muffin > "$BK/death_muffin.sql"
cp -a "$RUNTIME/backend/chronicle.cjs" "$BK/backend/"
cp -a "$RUNTIME/backend/gathering/"*.cjs "$BK/backend/gathering/"
cp -a "$RUNTIME/backend/necro-progress/necro-rules.cjs" "$BK/backend/necro-progress/"
cp -a "$RUNTIME/realtime/server.js" "$BK/realtime/"
sudo cp -a "$PUBLIC/index.html" "$BK/play/"
(cd "$BK" && sha256sum death_muffin.sql backend/chronicle.cjs backend/gathering/*.cjs backend/necro-progress/necro-rules.cjs realtime/server.js play/index.html > SHA256SUMS && sha256sum -c SHA256SUMS)

cat > "$BK/ROLLBACK.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
BK='$BK'
RUNTIME='$RUNTIME'
PUBLIC='$PUBLIC'
cp -a "\$BK/backend/chronicle.cjs" "\$RUNTIME/backend/"
cp -a "\$BK/backend/gathering/"*.cjs "\$RUNTIME/backend/gathering/"
cp -a "\$BK/backend/necro-progress/necro-rules.cjs" "\$RUNTIME/backend/necro-progress/"
cp -a "\$BK/realtime/server.js" "\$RUNTIME/realtime/"
sudo systemctl restart death-muffin-auth.service death-muffin-realtime.service
sudo cp -a "\$BK/play/index.html" "\$PUBLIC/index.html"
echo 'Code and index restored. Additive item rows are retained; player data is untouched.'
EOF
chmod 700 "$BK/ROLLBACK.sh"

for n in 013-necro-weapons 014-alchemy-reagents 015-fen; do
  sudo mysql death_muffin < "$SRC/server/death-muffin/backend/migrations/$n.sql"
done

cp -a "$SRC/server/death-muffin/backend/chronicle.cjs" "$RUNTIME/backend/"
cp -a "$SRC/server/death-muffin/backend/gathering/"*.cjs "$RUNTIME/backend/gathering/"
cp -a "$SRC/server/vps-handoff/necro-progress/necro-rules.cjs" "$RUNTIME/backend/necro-progress/"
cp -a "$SRC/server/realtime/server.js" "$RUNTIME/realtime/"
sudo systemctl restart death-muffin-auth.service death-muffin-realtime.service
sudo systemctl is-active death-muffin-auth.service death-muffin-realtime.service
curl --silent --show-error --fail --retry 8 --retry-delay 1 --retry-all-errors https://muffindevelopment.com/death-muffin/api/health

# Keep old hashed bundles for open tabs. Switch the entry page only after all assets are present.
sudo cp -a "$SRC/dist/assets" "$SRC/dist/art" "$SRC/dist/models" "$SRC/dist/fx" "$SRC/dist/audio" "$PUBLIC/"
sudo cp -a "$SRC/dist/index.html" "$PUBLIC/index.html"
sudo chown -R root:root "$PUBLIC"
sudo chmod -R a+rX "$PUBLIC"
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/play/ -o "$BK/live-index.html"
cmp "$BK/live-index.html" "$SRC/dist/index.html"
echo "Release published. Backup and rollback: $BK"
