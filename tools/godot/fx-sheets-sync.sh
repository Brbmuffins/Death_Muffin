#!/usr/bin/env bash
# Copy the licensed flipbook sheets (fx_data.json `sheets`) into a checkout: <checkout>/client/assets/fx/sheets/<id>.png.
# The pack may not be published in a public repository, so the sheets live outside git in $FX_SHEETS (default
# ~/death-muffin/private/fx-sheets). The publish's PREPARE (server/death-muffin/test-channel/prepare-rebuild.sh) runs this on its export worktree;
# run it once in a new worktree to see them.
# Fails (exit 1) when a listed sheet is missing, so a publish never ships without them. Without the sheets the game draws its plain look.
#
#   bash tools/godot/fx-sheets-sync.sh [<checkout>]      (default: this script's checkout)
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRC="${FX_SHEETS:-/home/ubuntu/death-muffin/private/fx-sheets}"
DEST="$ROOT/client/assets/fx/sheets"
IDS=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("sheets", {})))' "$ROOT/client/assets/fx/fx_data.json")
mkdir -p "$DEST"
# Only the images: the game imports them with its own settings and writes their .import files itself (path-based ids, the same in every checkout,
# so the assets pack's fingerprint holds from one publish to the next).
for id in $IDS; do
  f="$id.png"
  [ -f "$SRC/$f" ] || { echo "fx-sheets-sync: $SRC/$f is missing" >&2; exit 1; }
  cmp -s "$SRC/$f" "$DEST/$f" || cp "$SRC/$f" "$DEST/$f"
done
echo "fx-sheets-sync: $(echo $IDS | wc -w) sheets in $DEST"
