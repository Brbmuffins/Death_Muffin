#!/usr/bin/env bash
# Copies exactly the GLBs/textures the Godot slice uses (godot/data/slice/assets_used.json, written by export-slice.ts)
# from public/ into godot/assets/slice/ (same relative paths). Run export-slice first: npx vite-node tools/godot/export-slice.ts
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIST="$ROOT/godot/data/slice/assets_used.json"
[ -f "$LIST" ] || { echo "missing $LIST: run export-slice.ts first" >&2; exit 1; }
python3 - "$ROOT" "$LIST" <<'PY'
import json, shutil, sys, os
root, lst = sys.argv[1], sys.argv[2]
d = json.load(open(lst))
n = 0; total = 0
for rel in d["models"] + d["textures"]:
    src = os.path.join(root, "public", rel)
    dst = os.path.join(root, "godot", "assets", "slice", rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not os.path.exists(dst) or os.path.getmtime(src) > os.path.getmtime(dst) or os.path.getsize(src) != os.path.getsize(dst):
        shutil.copy2(src, dst)
    n += 1; total += os.path.getsize(dst)
print(f"synced {n} files, {total/1048576:.1f} MB -> godot/assets/slice/")
PY
