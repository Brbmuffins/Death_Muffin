#!/usr/bin/env bash
# Imports the game's project and rebuilds area scenes (client/areas/<id>.tscn) from client/data/slice/world.json.
#   tools/rebuild/build-areas.sh [area id ...]        default: graves
# Run client/setup.sh once in the checkout first. Godot runs headless at low priority (the VPS also runs live games). Exit 1 when a listed
# asset is missing or the converter fails; see client/README.md "Assets" and "Areas".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
AREAS=("$@")
[ ${#AREAS[@]} -gt 0 ] || AREAS=(graves)

import_project() { nice -n 10 "$GODOT" --headless --path "$ROOT/client" --import >/dev/null 2>&1 || true; }
convert() { nice -n 10 "$GODOT" --headless --path "$ROOT/client" --script res://tools/build_area.gd -- "${AREAS[@]}"; }

import_project
rc=0
convert || rc=$?
if [ "$rc" -eq 3 ]; then   # the converter wrote its generated decal textures: import them, then convert
  import_project
  rc=0
  convert || rc=$?
fi
exit "$rc"
