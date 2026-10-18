#!/usr/bin/env bash
# The fingerprint of the game's assets pack (DeathMuffin.assets.pck, tools/godot/assets-pack.sh): what the pack is built from. While it is
# unchanged, publish-godot-client.sh reuses the cached pack, so it keeps its SHA-256 and the launcher skips the ~500 MB download.
#   tools/godot/assets-fp.sh <checkout> [godot binary]     prints 16 hex characters
#   tools/godot/assets-fp.sh --paths                       prints the repository paths it reads (the Discord agent's preview: same as live?)
# Run it on a checkout prepared the way the publish prepares one (the licensed flipbook sheets copied in: they count).
set -euo pipefail
BAKER=(client/crowd/crowd_baker.gd client/crowd/crowd_vat_data.gd client/crowd/crowd_looks.json client/tools/bake_crowd.gd client/tools/bake_crowd.sh
  client/game/dm_creature.gd client/game/dm_creature_mat.gd client/game/dm_gear_props.gd client/world/dm_models.gd client/world/dm_animator.gd
  client/game/view_models.json)
SETTINGS=(client/export_presets.cfg client/project.godot tools/godot/assets-pack.sh tools/godot/export-baked.sh tools/godot/pck_extract.py tools/godot/pck_pack.gd)
if [ "${1:-}" = --paths ]; then printf '%s\n' client/assets "${BAKER[@]}" client/data/content/enemies.json "${SETTINGS[@]}"; exit 0; fi
WT="${1:?usage: assets-fp.sh <checkout> [godot]}"
GODOT="${2:-${GODOT:-/home/ubuntu/tools/godot/godot}}"
{ echo client
  # The crowd's bakes (client/assets/crowd/baked, generated: not byte-reproducible) count by their inputs, below, not their bytes.
  (cd "$WT/client" && find assets -path assets/crowd/baked -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
  # Every file the baker reads: its own, the creature, model, animator and hand-prop code it poses with, and the model rows.
  (cd "$WT" && sha256sum "${BAKER[@]}")
  # Of the enemy table, only each enemy's model (CrowdBaker.model_for): retuning an enemy must not cost players the pack again.
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])).get("ENEMIES", {}); print(json.dumps({k: v.get("modelSlug") for k, v in d.items()}, sort_keys=True))' \
    "$WT/client/data/content/enemies.json" | sha256sum
  (cd "$WT" && sha256sum "${SETTINGS[@]}")
  "$GODOT" --version; } | sha256sum | cut -c1-16
