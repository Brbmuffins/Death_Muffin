#!/usr/bin/env bash
# Copy the licensed flipbook sheets (fx_data.json `sheets`) into a checkout: <checkout>/godot/assets/fx/sheets/<id>.png + .png.import.
# The pack may not be published in a public repository, so the sheets live outside git in $FX_SHEETS (default
# ~/death-muffin/private/fx-sheets). publish-godot-client.sh runs this on its export worktree; run it once in a new worktree to see them.
# Fails (exit 1) when a listed sheet is missing, so a publish never ships without them. Without the sheets the game draws its plain look.
#
#   bash tools/godot/fx-sheets-sync.sh [<checkout>]      (default: this script's checkout)
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRC="${FX_SHEETS:-/home/ubuntu/death-muffin/private/fx-sheets}"
DEST="$ROOT/godot/assets/fx/sheets"
IDS=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("sheets", {})))' "$ROOT/godot/assets/fx/fx_data.json")
mkdir -p "$DEST"
for id in $IDS; do
  for f in "$id.png" "$id.png.import"; do
    [ -f "$SRC/$f" ] || { echo "fx-sheets-sync: $SRC/$f is missing" >&2; exit 1; }
    cmp -s "$SRC/$f" "$DEST/$f" || cp "$SRC/$f" "$DEST/$f"
  done
done
echo "fx-sheets-sync: $(echo $IDS | wc -w) sheets in $DEST"
