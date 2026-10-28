#!/usr/bin/env bash
# Stand-in for model-run.sh (no team PC, no ComfyUI): makes fake tries the way the real one leaves them (<label>.glb and tries.json in art-src/comfy/<id>/). Behaviour
# switches are files next to this script: model-hold (waits while it exists), model-fail (a failed run), model-tries (how many tries arrive, default 3).
d=$(cd "$(dirname "$0")" && pwd); ID=${1:-}
echo "model-run $ID gen=${DM_MODEL_GEN:-} workflow=${DM_MODEL_WORKFLOW:-}" >> "$d/calls.log"
[ -f "art-src/concepts/$ID.png" ] || { echo "RESULT: no-concept"; exit 2; }
while [ -e "$d/model-hold" ]; do sleep 0.1; done
[ -e "$d/model-fail" ] && { echo "model gen: no team PC runs model jobs"; echo "RESULT: failed"; exit 5; }
mkdir -p "art-src/comfy/$ID"
python3 - "$ID" "$(cat "$d/model-tries" 2>/dev/null || echo 3)" <<'PY'
import json, os, sys
id, n = sys.argv[1], int(sys.argv[2]); out = "art-src/comfy/" + id; tries = []
for s in range(n):
    label = "%s-s%d" % (id.replace("_", "-")[:21], s)
    open(os.path.join(out, label + ".glb"), "w").write("glb " + label)
    tries.append({"label": label, "model": "pixal3d", "faces": 200000, "texture": 2048, "seed": s, "settings": {"detail": 2048, "grid": 1024}, "comfyui": "0.0.0", "template": "fake (templates 0)",
                  "teamApp": None, "pc": None, "job": "fake00000000", "date": "2026-01-01", "file": label + ".glb"})
json.dump(tries, open(os.path.join(out, "tries.json"), "w"))
PY
echo "RESULT: ok"
