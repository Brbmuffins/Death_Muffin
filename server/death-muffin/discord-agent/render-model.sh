#!/usr/bin/env bash
# Review renders of built models, for the thread: render-model.sh <id> [<id> ...]   (1 to 6 ids; run from the worktree root after build-art.sh)
# Each id is a model in this worktree: prop_<name> -> client/assets/slice/models/props/<name>.glb, otherwise client/assets/slice/models/<id>/character.glb
# (existing models work too, e.g. to show an old piece next to a new one). Blender (Cycles, CPU, 4 threads, low samples) renders front / side / back of
# each one inside the same sandbox as check-godot.sh (sandbox-lib.sh: no network, read-only filesystem, only the worktree writable), composes one sheet
# (a row per model) and label-shot.py (trusted, outside the sandbox) burns "BRANCH PREVIEW · not live" in and writes .dm-shots/models-<first id>.png,
# which the runner posts in the thread after the turn. One renderer at a time with the screenshots (the shared qa-browser.lock), 10 minute limit.
# Env: BLENDER (default /home/ubuntu/tools/blender/blender), DM_BROWSER_LOCK, DM_SHOT_LABEL_PY (tests).
set -uo pipefail
[ $# -ge 1 ] && [ $# -le 6 ] || { echo "usage: render-model.sh <id> [<id> ...]   (1 to 6 model ids)"; exit 2; }
TOP=$(git rev-parse --show-toplevel) || exit 2
TOOLS=$(cd "$(dirname "$0")" && pwd)
MODELS=""
for ID in "$@"; do
  [[ "$ID" =~ ^[a-z0-9_]{3,40}$ ]] || { echo "bad id: $ID"; exit 2; }
  case "$ID" in prop_*) REL="client/assets/slice/models/props/${ID#prop_}.glb";; *) REL="client/assets/slice/models/$ID/character.glb";; esac
  [ -f "$TOP/$REL" ] && [ ! -L "$TOP/$REL" ] || { echo "no model for $ID at $REL (run build-art.sh $ID first)"; exit 2; }
  MODELS="$MODELS $ID=$REL"
done
NAME="models-$(echo "$1" | tr '_' '-' | cut -c1-33)"
DM_SHOT_BRANCH=$(git -C "$TOP" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
PYUB=$(python3 -m site --user-base 2>/dev/null || true)   # Pillow may be a user install; the sandbox HOME is a fresh temp dir
export TOP TOOLS MODELS NAME PYUB BLENDER="${BLENDER:-/home/ubuntu/tools/blender/blender}"
export DM_SANDBOX_LIB="$TOOLS/sandbox-lib.sh"
LOCK=${DM_BROWSER_LOCK:-/home/ubuntu/death-muffin/qa-browser.lock}
RAW="$TOP/.dm-shots/.raw"
[ -L "$TOP/.dm-shots" ] && { echo ".dm-shots must not be a symlink"; exit 2; }
rm -rf "$RAW" 2>/dev/null; mkdir -p "$RAW" || exit 2
export DM_PAYLOAD='
  set -uo pipefail
  SCR=$(mktemp -d /tmp/dmrender.XXXXXX)
  export HOME="$SCR/home"; mkdir -p "$HOME"
  cd "$TOP"
  ARGS=""; for m in $MODELS; do ARGS="$ARGS ${m%%=*}=$TOP/${m#*=}"; done
  nice -n 10 "$BLENDER" -b --factory-startup --python "$TOOLS/render-model.py" -- "$SCR/out" $ARGS > "$SCR/blender.log" 2>&1
  rc=$?
  grep -E "^RENDERED|Error|error:" "$SCR/blender.log" | head -20
  [ $rc -eq 0 ] || { echo "blender exited $rc"; tail -15 "$SCR/blender.log"; exit $rc; }
  PYTHONUSERBASE="$PYUB" python3 - "$SCR/out" "$TOP/.dm-shots/.raw/$NAME.png" $MODELS <<'"'"'PY'"'"'
import os, sys
from PIL import Image, ImageDraw, ImageFont
src, dst, models = sys.argv[1], sys.argv[2], [m.split("=")[0] for m in sys.argv[3:]]
views = ["front", "side", "back"]
tiles = [[Image.open(os.path.join(src, f"{n}_{v}.png")).convert("RGB") for v in views] for n in range(len(models))]
w, h = tiles[0][0].size
head = 34
sheet = Image.new("RGB", (w * 3, (h + head) * len(models)), (24, 22, 28))
d = ImageDraw.Draw(sheet)
font = None
for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"):
    if os.path.exists(f):
        font = ImageFont.truetype(f, 20); break
for n, row in enumerate(tiles):
    y = n * (h + head)
    txt = f"{models[n]}   front · side · back"
    tw = d.textlength(txt, font=font) if font else len(txt) * 7
    d.text((w * 3 - tw - 12, y + 6), txt, fill=(230, 220, 255), font=font)   # right-aligned: the preview badge sits top-left
    for i, t in enumerate(row):
        sheet.paste(t, (i * w, y + head))
sheet.save(dst)
print("SHEET", dst, sheet.size)
PY
'
flock -w 900 "$LOCK" timeout -k 20 600 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
[ $rc -eq 124 ] || [ $rc -eq 137 ] && echo "rendering timed out after 10 minutes"
python3 "${DM_SHOT_LABEL_PY:-$TOOLS/label-shot.py}" "$TOP" "$DM_SHOT_BRANCH"; lrc=$?
rm -rf "$RAW" 2>/dev/null
[ $lrc -eq 0 ] || exit 3
[ $rc -eq 0 ] && echo "RENDERED: .dm-shots/$NAME.png (read it; the runner posts it in the thread after your turn)"
exit $rc
