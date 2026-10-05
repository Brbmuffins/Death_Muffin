#!/usr/bin/env bash
# Copy the UI art the panels and tooltips draw (item icons, ability icons, omens, class portraits, status icons, skill icons, HUD currency art) from
# public/art to godot/assets/ui_art/art/<dir>, keeping the web's relative paths ("art/items/x.webp") so DmUiArt resolves them 1:1.
# ~4 MB of webp/svg. Then run `godot --headless --path godot --import` (commit the generated .import files).
set -euo pipefail
cd "$(dirname "$0")/../.."
for d in items abilities omens portraits status skills ui; do
  mkdir -p "godot/assets/ui_art/art/$d"
  cp -u public/art/$d/* "godot/assets/ui_art/art/$d/"
done
echo "synced: $(find godot/assets/ui_art -type f | wc -l) files, $(du -sh godot/assets/ui_art | cut -f1)"
