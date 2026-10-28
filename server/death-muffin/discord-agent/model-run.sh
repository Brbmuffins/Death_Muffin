#!/usr/bin/env bash
# Runner-only (never in the agent's allowedTools, and the agent has no shell to reach it): make three 3D tries of ONE concept picture on a team PC.
#   model-run.sh <id>     run from the job's worktree; the picture is art-src/concepts/<id>.png (the runner checked it is the one people saw)
# Pixal3D (ComfyUI) on a team PC's graphics card: free, no key. The trusted model-gen.sh queues ONE `model` job of three runs (seeds 0, 1, 2) and copies <label>.glb and the PC's
# <job id>.log into art-src/comfy/<id>/; this script then writes art-src/comfy/<id>/tries.json there: one entry per try that arrived, each the `run` block of the model's
# record art-manifest/comfy/<id>.json ({label, model, faces, texture, seed, settings, comfyui, template, teamApp, pc, job, date, file}). A new request starts from nothing: the
# earlier tries of these labels and tries.json go first. teamApp and pc stay null: neither model-gen.sh nor the PC's log says them.
# Env (set by the runner for this one child): DM_MODEL_GEN (the INSTALLED model-gen.sh, never the worktree's copy: the agent can edit that) and what model-gen.sh itself reads
# (DM_MODEL_WORKFLOW, DM_TEAM_API, DM_TEAM_SECRET_FILE ...; inherited, never read or printed here); DM_MODEL_WAIT_MIN (50): minutes before model-gen.sh cancels its team job.
# Output: model-gen.sh's own lines, then RESULT: ok | failed | timeout | bad-id | no-concept | no-tools. Exit: 0 ok, 2 a problem with the id, the picture or the tools, 3 timeout, 5 failed.
set -uo pipefail
ID=${1:-}
[[ "$ID" =~ ^[a-z0-9_]{3,40}$ ]] || { echo "RESULT: bad-id"; exit 2; }
PIC="art-src/concepts/$ID.png"
[ -f "$PIC" ] && [ ! -L "$PIC" ] || { echo "RESULT: no-concept"; exit 2; }
GEN=${DM_MODEL_GEN:-}
[ -n "$GEN" ] && [ -f "$GEN" ] && command -v python3 >/dev/null || { echo "RESULT: no-tools"; exit 2; }
TMP=$(mktemp -d) || { echo "RESULT: no-tools"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
OUT="art-src/comfy/$ID"
# a run's label is a team-app name: lowercase letters, digits and - (at most 24, starting with a letter or digit), so the id's _ become - and its end is cut to leave room for -sN
SLUG=$(printf '%s' "$ID" | tr '_' '-' | sed 's/^-*//' | cut -c1-21 | sed 's/-*$//'); SLUG=${SLUG:-model}
python3 - "$ID" "$SLUG" > "$TMP/runs.json" <<'PY'
import json, sys
id, slug = sys.argv[1:3]
print(json.dumps([{"label": "%s-s%d" % (slug, s), "image": id + ".png", "model": "pixal3d", "faces": 200000, "texture": 2048, "seed": s, "settings": {"detail": 2048, "grid": 1024}} for s in range(3)], indent=1))
PY
[ -s "$TMP/runs.json" ] || { echo "RESULT: no-tools"; exit 2; }
mkdir -p "$OUT" || { echo "RESULT: no-tools"; exit 2; }
rm -f "$OUT/tries.json" "$OUT/$SLUG"-s0.glb "$OUT/$SLUG"-s1.glb "$OUT/$SLUG"-s2.glb
bash "$GEN" --runs "$TMP/runs.json" --wait "${DM_MODEL_WAIT_MIN:-50}" "$OUT/" "$PIC" 2>&1 | tee "$TMP/gen.out"
rc=${PIPESTATUS[0]}
# tries.json: what arrived, with the run details from the PC's log of the job (the log's name is the job id; model-gen.sh prints its path)
N=$(python3 - "$OUT" "$TMP/runs.json" "$TMP/gen.out" <<'PY'
import datetime, json, os, re, sys
out, runs_file, gen_file = sys.argv[1:4]
runs = json.load(open(runs_file))
logs = re.findall(r"^model gen: \S*?([0-9A-Za-z]+)\.log\s*$", open(gen_file, errors="replace").read(), re.M)
job = logs[-1] if logs else None
log = open(os.path.join(out, job + ".log"), errors="replace").read() if job and os.path.isfile(os.path.join(out, job + ".log")) else ""
m = re.search(r"workflow: ComfyUI ([^,\s]+), template ([^;\n]*?)\s*(?:;|$)", log, re.M)
comfyui, template = (m.group(1), m.group(2)) if m else (None, None)
app = re.search(r"team app (\d+(?:\.\d+)+)", log)
today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
tries = []
for r in runs:
    f = os.path.join(out, r["label"] + ".glb")
    if os.path.isfile(f) and not os.path.islink(f):
        tries.append({"label": r["label"], "model": r["model"], "faces": r["faces"], "texture": r["texture"], "seed": r["seed"], "settings": r["settings"],
                      "comfyui": comfyui, "template": template, "teamApp": app.group(1) if app else None, "pc": None, "job": job, "date": today, "file": r["label"] + ".glb"})
if tries:
    with open(os.path.join(out, "tries.json"), "w") as w:
        json.dump(tries, w, indent=1)
        w.write("\n")
print(len(tries))
PY
)
if [ "$rc" -eq 0 ] && [ "${N:-0}" -gt 0 ]; then echo "RESULT: ok"; exit 0; fi
if grep -q 'did not finish in time' "$TMP/gen.out"; then echo "RESULT: timeout"; exit 3; fi
echo "RESULT: failed"; exit 5
