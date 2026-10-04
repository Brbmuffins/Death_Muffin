#!/usr/bin/env bash
# Copy the HUD art the world needs (ability icons, omens, portraits, status icons) from public/art to godot/assets/game/art.
set -euo pipefail
cd "$(dirname "$0")/../.."
for d in abilities omens portraits status; do
  mkdir -p "godot/assets/game/art/$d"
  cp -u public/art/$d/* "godot/assets/game/art/$d/"
done
