#!/usr/bin/env bash
# Undo launch day (DECISIONS B40; the window closes 2026-11-01): the launcher goes back to today's old game, the last build of godot/ that was
# live before the rebuild. The launch kept that build's folder and manifest in $KEEP (outside the web folder, so publishes never prune it). This
# puts the folder back next to the live builds and writes its manifest as the live one, carrying over the online block that is live now.
# The backend, lobby and relay need nothing: they accept the old client and the rebuilt one alike.
#   launch-undo.sh            # the launcher offers the old build again
#   launch-undo.sh --check    # only says what it would restore
set -euo pipefail
KEEP="${KEEP:-/home/ubuntu/death-muffin/launch-undo}"
OUT_DIR="${OUT_DIR:-/var/www/death-muffin/client}"
[ -f "$KEEP/manifest.json" ] || { echo "no kept manifest in $KEEP" >&2; exit 1; }
V=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$KEEP/manifest.json")
[ -d "$KEEP/$V" ] || { echo "the kept build folder $KEEP/$V is missing" >&2; exit 1; }
if [ "${1:-}" = --check ]; then
  echo "would restore $V (live now: $(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$OUT_DIR/manifest.json"))"
  exit 0
fi
[ -d "$OUT_DIR/$V" ] || cp -a "$KEEP/$V" "$OUT_DIR/$V"
python3 - "$KEEP/manifest.json" "$OUT_DIR/manifest.json" <<'PY'
import json, os, sys
old = json.load(open(sys.argv[1]))
cur = json.load(open(sys.argv[2]))
old["online"] = cur.get("online", old.get("online"))
tmp = sys.argv[2] + ".tmp"
with open(tmp, "w") as f:
    json.dump(old, f, indent=2)
os.replace(tmp, sys.argv[2])
PY
echo "the launcher offers $V again (the old game); the rebuilt build's folder stays in $OUT_DIR"
