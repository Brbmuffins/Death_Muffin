#!/usr/bin/env bash
# Publish a build to the launcher's Test build channel (DECISIONS B38) from a COMMITTED revision:
#   publish-test-channel.sh <git-rev>
# Runs publish-godot-client.sh for the rebuilt client (PROJECT=client: its own project, DECISIONS B41) with the test channel's folder, URL
# and its own work folder (so the live asset-pack cache is never touched), no announcement, and prepare-rebuild.sh (the combat core,
# the sheets, the crowd's baked models). The rebuild talks to the test backend by its own config (client/net/dm_config.gd).
# Served at https://muffindevelopment.com/death-muffin/client-test/; the launcher's Test build switch installs from its manifest.json.
set -euo pipefail
REV="${1:?usage: publish-test-channel.sh <git-rev>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=/var/www/death-muffin/client-test
if [ ! -d "$OUT" ]; then sudo mkdir -p "$OUT" && sudo chown ubuntu:ubuntu "$OUT"; fi
# The publish carries the online block over from the manifest it replaces: the test channel is always open (only the team's accounts
# exist on the test backend).
[ -f "$OUT/manifest.json" ] || echo '{"online": {"enabled": true, "staff": false, "message": "Test build"}}' > "$OUT/manifest.json"
OUT_DIR="$OUT" BASE_URL=https://muffindevelopment.com/death-muffin/client-test WORK=/home/ubuntu/death-muffin/deploy-test \
  NO_ANNOUNCE=1 LOBBY_SKEW_OK=1 KEEP_BUILDS=2 PROJECT=client PREPARE="$HERE/prepare-rebuild.sh" SMOKE="$HERE/smoke-rebuild.sh" \
  bash "$HERE/../publish-godot-client.sh" "$REV"
