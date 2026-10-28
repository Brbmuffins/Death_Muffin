#!/usr/bin/env bash
# Review renders of models, for the thread: render-model.sh <model> [<model> ...]   (1 to 6; run from the worktree root)
# A model is an id of a built model in this worktree: prop_<name> -> client/assets/slice/models/props/<name>.glb, otherwise
# client/assets/slice/models/<id>/character.glb (existing models work too, e.g. to show an old piece next to a new one), or a file of a model made
# from a ComfyUI run (guides/models.md): art-src/comfy/<id>/<label>.glb (a Pixal try, as it came), art-src/comfy/<id>/game.glb or
# art-src/comfy/<id>/work/<file>.glb (in the game placement). A model is turned the way the game turns it (its row's yaw in client/data/slice, half a
# turn for a file in the game placement, which faces away from the game's camera like the hounds), so "front" is the side players see. Blender
# (Cycles, CPU, 4 threads, low samples) renders front / side / back of each one inside the same sandbox as check-godot.sh (sandbox-lib.sh: no
# network, read-only filesystem, only the worktree writable), composes one sheet (a row per model) and label-shot.py (trusted, outside the sandbox)
# burns "BRANCH PREVIEW · not live" in and writes .dm-shots/models-<first id>.png, which the runner posts in the thread after the turn. One renderer
# at a time with the screenshots (the shared qa-browser.lock), 10 minute limit.
# Env: BLENDER (default /home/ubuntu/tools/blender/blender), DM_BROWSER_LOCK, DM_SHOT_LABEL_PY (tests).
set -uo pipefail
[ $# -ge 1 ] && [ $# -le 6 ] || { echo "usage: render-model.sh <model> [<model> ...]   (1 to 6: model ids or art-src/comfy/<id>/... .glb files)"; exit 2; }
TOP=$(git rev-parse --show-toplevel) || exit 2
TOOLS=$(cd "$(dirname "$0")" && pwd)
MODELS=""; FIRST=""
for ARG in "$@"; do
  if [[ "$ARG" =~ ^art-src/comfy/([a-z0-9_]{3,40})/(work/)?([a-z0-9][a-z0-9._-]{0,60})\.glb$ ]]; then
    ID=${BASH_REMATCH[1]}; REL=$ARG; LABEL="$ID/${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    TURN=0; [ -n "${BASH_REMATCH[2]}" ] || [ "${BASH_REMATCH[3]}" = game ] && TURN=180
    [ "$(realpath -m "$TOP/$REL")" = "$TOP/$REL" ] || { echo "$REL must not go through a symlink"; exit 2; }
  elif [[ "$ARG" =~ ^[a-z0-9_]{3,40}$ ]]; then
    ID=$ARG; LABEL=$ID
    case "$ID" in prop_*) REL="client/assets/slice/models/props/${ID#prop_}.glb";; *) REL="client/assets/slice/models/$ID/character.glb";; esac
    TURN=$(python3 - "$TOP" "${REL#client/assets/slice/}" <<'PY'
import json, math, sys
def rows(x):
    if isinstance(x, dict):
        if isinstance(x.get('url'), str):
            yield x
        for v in x.values():
            yield from rows(v)
    elif isinstance(x, list):
        for v in x:
            yield from rows(v)
for f in ('enemies', 'npcs', 'hero'):
    for r in rows(json.load(open(f'{sys.argv[1]}/client/data/slice/{f}.json'))):
        if r['url'] == sys.argv[2]:
            print(round(math.degrees(float(r.get('yaw', 0)))))
            sys.exit()
print(0)
PY
) || TURN=0
  else
    echo "bad model: $ARG (an id, or art-src/comfy/<id>/<file>.glb)"; exit 2
  fi
  [ -f "$TOP/$REL" ] && [ ! -L "$TOP/$REL" ] || { echo "no model for $ARG at $REL (an id: run build-art.sh $ID first)"; exit 2; }
  MODELS="$MODELS $LABEL=$REL=$TURN"; FIRST=${FIRST:-$ID}
done
NAME="models-$(echo "$FIRST" | tr '_' '-' | cut -c1-33)"
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
  ARGS=""; for m in $MODELS; do ARGS="$ARGS ${m%%=*}=$TOP/${m#*=}"; done   # label=<path>=<turn>
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
