#!/usr/bin/env bash
# Build DeathMuffin.assets.pck (everything under res://assets) for publish-godot-client.sh, from an imported checkout:
#   bash tools/godot/assets-pack.sh <checkout>/client <out.pck> [godot-binary]
# 1. `--export-pack "Windows Assets"` (export_presets.cfg: include res://assets/*), with the art's shaders baked when a renderer is free (export-baked.sh).
# 2. Keeps only assets/, .godot/imported/, .godot/exported/ and .godot/shader_cache/ (the baked shaders) entries: Godot also writes project.binary, the uid and script-class caches
#    and the autoload scripts into every pack, and those change with every code change. Without them the pack depends on res://assets
#    alone, so the publish can reuse it as-is while assets are unchanged (Godot's export is not byte-reproducible, see main/dm_packs.gd).
set -euo pipefail
PROJ="${1:?usage: assets-pack.sh <godot project dir> <out.pck> [godot]}"; OUT="${2:?out.pck}"; GODOT="${3:-/home/ubuntu/tools/godot/godot}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
bash "$HERE/export-baked.sh" "$PROJ" pack "Windows Assets" "$TMP/full.pck" "$GODOT" || { echo "assets export failed" >&2; exit 1; }
python3 "$HERE/pck_extract.py" "$TMP/full.pck" "$TMP/files" > "$TMP/list.txt"
rm -f "$TMP/full.pck"
[ -s "$TMP/list.txt" ] || { echo "assets pack: nothing kept" >&2; exit 1; }
"$GODOT" --headless --path "$PROJ" --script "$HERE/pck_pack.gd" -- "$TMP/files" "$TMP/list.txt" "$OUT" >"$TMP/pack.log" 2>&1 || { tail -20 "$TMP/pack.log" >&2; echo "assets repack failed" >&2; exit 1; }
[ "$(stat -c %s "$OUT" 2>/dev/null || echo 0)" -gt 1000000 ] || { echo "assets pack missing or suspiciously small" >&2; exit 1; }
echo "assets pack: $(wc -l < "$TMP/list.txt") files, $(stat -c %s "$OUT") bytes"
