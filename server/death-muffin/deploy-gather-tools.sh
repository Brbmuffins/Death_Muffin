#!/usr/bin/env bash
set -euo pipefail

SOURCE=/home/ubuntu/vps-handoffs/DeathMuffin/game
PUBLIC=/var/www/death-muffin/play
BACKUP=${1:?Pass the pre-release static-client backup directory}

# The old index and its hashed bundles remain available for a code-only rollback.
test -f "$SOURCE/dist/index.html"
test -f "$BACKUP/index.html"
(cd "$BACKUP" && sha256sum -c SHA256SUMS >/dev/null)
cmp "$BACKUP/index.html" "$PUBLIC/index.html"
for tool in hatchet pickaxe fishing_rod spade; do
  cmp "$SOURCE/public/models/props/tool_${tool}.glb" "$PUBLIC/models/props/tool_${tool}.glb"
done

# Only client code changed. Publish the new hashed bundle before the entry page.
cp -a "$SOURCE/dist/assets" "$PUBLIC/"
cp -a "$SOURCE/dist/index.html" "$PUBLIC/index.html"

curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/play/ -o /tmp/death-muffin-gather-tools-live.html
cmp /tmp/death-muffin-gather-tools-live.html "$SOURCE/dist/index.html"
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/api/health
echo
echo "Gathering visuals published. Previous index: $BACKUP/index.html"
