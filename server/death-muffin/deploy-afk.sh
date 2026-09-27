#!/bin/bash
set -euo pipefail
AFK_SOURCE=/home/ubuntu/vps-handoffs/DeathMuffin/game
# Build with the correct same-origin API/socket paths and no source maps.
(cd "$AFK_SOURCE" && npm run build:death-muffin)
cp "$AFK_SOURCE/server/death-muffin/backend/gathering/gathering-rules.cjs" "$AFK_SOURCE/server/death-muffin/backend/gathering/gathering-routes.cjs" /home/ubuntu/death-muffin/backend/gathering/
cp "$AFK_SOURCE/server/vps-handoff/necro-progress/necro-rules.cjs" /home/ubuntu/death-muffin/backend/necro-progress/necro-rules.cjs
node --check /home/ubuntu/death-muffin/backend/gathering/gathering-routes.cjs
cp "$AFK_SOURCE/server/realtime/server.js" /home/ubuntu/death-muffin/realtime/server.js
node --check /home/ubuntu/death-muffin/realtime/server.js
sudo systemctl restart death-muffin-auth.service death-muffin-realtime.service
sudo systemctl is-active death-muffin-auth.service death-muffin-realtime.service
sudo cp -a "$AFK_SOURCE/dist/assets" /var/www/death-muffin/play/
sudo cp -a "$AFK_SOURCE/dist/index.html" /var/www/death-muffin/play/index.html
sudo chown -R root:root /var/www/death-muffin/play/assets
sudo chmod -R a+rX /var/www/death-muffin/play/assets
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/play/ -o /tmp/death-muffin-afk-live.html
cmp /tmp/death-muffin-afk-live.html "$AFK_SOURCE/dist/index.html"
curl --silent --show-error --fail https://muffindevelopment.com/death-muffin/api/health
