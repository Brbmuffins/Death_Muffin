#!/usr/bin/env bash
# Eyes on a model from a session (client/main/SCREENSHOTS.md "Model view", DECISIONS B75): a team PC opens a model in the game itself, on its GPU at 1080p, and
# sends back pictures or videos, so a model made or changed here (in Blender, by hand) is seen in the game's own light before it is proposed.
#
#   model-view.sh [--tree <checkout>] [--pc <name or user>] <plan.json> <out dir> [<model.glb> ...]
#
# <plan.json>: a shot plan ({"shots": [...]}, client/main/qa_ui_shots.gd) or a clip plan ({"clips": [...]}, client/main/qa_clips.gd) whose shots or clips are model views:
# "view": "model" with "model": "<row id>" and/or "model_file": "<name>.glb" (shots), or "model" / "model_file" on a clip. Every "model_file" must be one of the .glb
# files given (each at most 60 MB); a plan without one looks at the build's own models.
# 1. The viewer: the debug build of <checkout> (default: origin/main, in a scratch worktree removed after) made by the agent's preview-godot.sh --team into
#    <team root>/<32 hex>/ (the art pack is the live one when the art is the live build's). The build of a clean revision is remembered in $DM_MV_STATE/viewer-<rev>.json
#    and used again while its files are there (preview-godot.sh keeps the newest 6 builds), so after the first look only the model is sent.
# 2. The models: copied into <team root>/view-<24 hex>/ (removed at the end; team-files-prune.sh takes one a killed run left), listed beside the build's files (the team
#    app puts them beside the game's exe).
# 3. ONE `shots` (Ultra) or `clip` (High, one variant with no tune) job, for the PC named by --pc (its name or its user's; default: whichever PC takes it), waited for
#    (shots 15 minutes, clips 25), then marked reported (nothing is posted anywhere).
# 4. The pictures and the mp4s copied to <out dir>; each mp4 also as <name>-sheet.jpg, eight moments of it side by side (ffmpeg), so a session can look at motion.
# Exit: 0 the results are in <out dir>, 1 the job failed or nothing came (the reason printed), 2 a usage, plan or build problem.
# Env: DM_TEAM_ROOT (/var/www/death-muffin/team-files), DM_TEAM_URL (https://muffindevelopment.com/death-muffin/team-files), DM_TEAM_API (http://127.0.0.1:5190),
#      DM_TEAM_SECRET_FILE (/home/ubuntu/death-muffin/discord-agent/secret), DM_MV_STATE (/home/ubuntu/death-muffin/model-view), DM_GAME_REPO (the checkout the scratch
#      worktree is made from: /home/ubuntu/vps-handoffs/DeathMuffin/game).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE=""; PC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE=${2:-}; shift 2 ;;
    --pc) PC=${2:-}; shift 2 ;;
    *) break ;;
  esac
done
[ $# -ge 2 ] || { echo "usage: $0 [--tree <checkout>] [--pc <name or user>] <plan.json> <out dir> [<model.glb> ...]" >&2; exit 2; }
PLAN=$1 OUT=$2; shift 2
STATE=${DM_MV_STATE:-/home/ubuntu/death-muffin/model-view}
mkdir -p "$STATE" "$OUT" || exit 2

# ---- the viewer build (TEAMFILES json), remembered per clean revision
SCRATCH=""
cleanup() { [ -z "$SCRATCH" ] || git -C "${DM_GAME_REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}" worktree remove --force "$SCRATCH" >/dev/null 2>&1; }
trap cleanup EXIT
if [ -z "$TREE" ]; then
  REPO=${DM_GAME_REPO:-/home/ubuntu/vps-handoffs/DeathMuffin/game}
  git -C "$REPO" fetch -q origin main || { echo "model view: cannot fetch origin/main" >&2; exit 2; }
  REV=$(git -C "$REPO" rev-parse origin/main)
else
  REV=$(git -C "$TREE" rev-parse HEAD) || { echo "model view: $TREE is not a checkout" >&2; exit 2; }
fi
CLEAN=1
[ -z "$TREE" ] || [ -z "$(git -C "$TREE" status --porcelain --untracked-files=no)" ] || CLEAN=""
BUILD="$STATE/viewer-$REV.json"
if [ -n "$CLEAN" ] && [ -s "$BUILD" ] && python3 - "$BUILD" "${DM_TEAM_ROOT:-/var/www/death-muffin/team-files}" "${DM_TEAM_URL:-https://muffindevelopment.com/death-muffin/team-files}" <<'PY'
import json, os, sys
files, root, base = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3].rstrip("/") + "/"
sys.exit(0 if all(f["url"].startswith(base) and os.path.isfile(os.path.join(root, f["url"][len(base):])) for f in files) else 1)
PY
then
  echo "model view: the viewer of ${REV:0:12} is built already"
else
  if [ -z "$TREE" ]; then
    SCRATCH=$(mktemp -d "$STATE/wt.XXXXXX") && rmdir "$SCRATCH" && git -C "$REPO" worktree add -q --detach "$SCRATCH" "$REV" || { echo "model view: no scratch worktree" >&2; exit 2; }
    TREE=$SCRATCH
  fi
  echo "model view: building the viewer of ${REV:0:12} (a few minutes the first time)"
  LOG="$STATE/build-${REV:0:12}.log"
  (cd "$TREE" && nice -n 10 bash server/death-muffin/discord-agent/preview-godot.sh "$(printf '%06x' $((RANDOM * 256 % 16777216)))" --team) >"$LOG" 2>&1
  LINE=$(grep '^TEAMFILES: ' "$LOG" | tail -n 1)
  [ -n "$LINE" ] || { echo "model view: the build failed (log: $LOG)" >&2; tail -n 5 "$LOG" >&2; exit 2; }
  TMPB=$(mktemp "$STATE/.viewer.XXXXXX")
  printf '%s\n' "${LINE#TEAMFILES: }" >"$TMPB"
  if [ -n "$CLEAN" ]; then mv "$TMPB" "$BUILD"; else BUILD="$TMPB"; fi
  cleanup; SCRATCH=""
fi

# ---- the job
exec python3 - "$PLAN" "$OUT" "$BUILD" "$REV" "$PC" "$@" <<'PY'
import hashlib, json, os, re, secrets, shutil, subprocess, sys, time, urllib.request

plan_path, out, build, rev, pc_want = sys.argv[1:6]
glbs = sys.argv[6:]
env = os.environ.get
root = env("DM_TEAM_ROOT") or "/var/www/death-muffin/team-files"
base_url = (env("DM_TEAM_URL") or "https://muffindevelopment.com/death-muffin/team-files").rstrip("/")
api = (env("DM_TEAM_API") or "http://127.0.0.1:5190").rstrip("/")
secret = open(env("DM_TEAM_SECRET_FILE") or "/home/ubuntu/death-muffin/discord-agent/secret").read().strip()
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,59}\.glb$")   # client/main/qa_model.gd FILE_RE
CLASSES = {"ossuary": 1, "gravecaller": 2, "mourner": 3, "rotweaver": 4, "reaper": 11}
MAX_GLB = 60 * 1024 * 1024


def die(code, message):
    print("model view: " + message, file=sys.stderr, flush=True)
    sys.exit(code)


def call(method, path, body=None):
    req = urllib.request.Request(api + "/internal/team" + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"content-type": "application/json", "x-team-secret": secret})
    with OPENER.open(req, timeout=20) as r:
        j = json.loads(r.read().decode())
    if not j.get("success"):
        raise RuntimeError(j.get("error") or "the backend refused")
    return j.get("data")


try:
    plan = json.load(open(plan_path))
except Exception as e:
    die(2, "the plan is not JSON (%s)" % e)
kind = "shots" if isinstance(plan, dict) and plan.get("shots") else "clip" if isinstance(plan, dict) and plan.get("clips") else ""
if not kind:
    die(2, "the plan needs a \"shots\" or a \"clips\" list")
given = {os.path.basename(g): g for g in glbs}
for name, g in given.items():
    if not FILE_RE.match(name) or not os.path.isfile(g) or os.path.islink(g) or os.path.getsize(g) > MAX_GLB:
        die(2, "%s: a model is a real .glb file of at most 60 MB, named with letters, digits, - and _" % g)
wanted = {s.get("model_file") for s in plan["shots" if kind == "shots" else "clips"] if isinstance(s, dict) and s.get("model_file")}
missing = sorted(w for w in wanted if w not in given)
if missing:
    die(2, "the plan names model files that were not given: " + ", ".join(missing))

files = json.load(open(build))
mv = ""
if given:
    mv = "view-" + secrets.token_hex(12)
    os.makedirs(os.path.join(root, mv), mode=0o755)
    for name, g in given.items():
        dst = os.path.join(root, mv, name)
        shutil.copyfile(g, dst)
        os.chmod(dst, 0o644)
        data = open(dst, "rb").read()
        files.append({"name": name, "url": "%s/%s/%s" % (base_url, mv, name), "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
code = 1
try:
    target = None
    pcs = call("GET", "/pcs") or []
    pcs = pcs if isinstance(pcs, list) else pcs.get("pcs", [])
    if pc_want:
        hit = [p for p in pcs if pc_want.lower() in (str(p.get("name", "")).lower(), str(p.get("username", "")).lower())]
        if not hit:
            die(2, "no team PC called %s is online (online: %s)" % (pc_want, ", ".join("%s (%s)" % (p.get("name"), p.get("username")) for p in pcs) or "none"))
        target = hit[0]["pcId"]
    elif not pcs:
        die(2, "no team PC is online")
    cls = CLASSES.get(str(plan.get("discipline", "")).lower().replace("hero_", ""), 2)
    payload = {"rev": rev[:12], "godotVersion": "4.7.2.stable", "files": files, "plan": plan, "args": ["--dev-offline", "--class=%d" % cls, "--qa"]}
    if kind == "shots":
        payload["presets"] = ["ultra"]
    else:
        payload["presets"] = ["high"]
        payload["variants"] = [{"label": "view", "tune": {}}]
    n = len(plan["shots" if kind == "shots" else "clips"])
    job = {"kind": kind, "title": "Model view: %d %s, about %d minutes" % (n, "pictures" if kind == "shots" else "videos", 2 if kind == "shots" else 3),
           "weightS": 120 if kind == "shots" else 180, "ttlS": 30 * 60, "payload": payload}
    if target:
        job["targetPc"] = target
    made = call("POST", "/jobs", job)
    jid = made["id"]
    print("model view: job %s queued%s" % (jid, " for " + pc_want if pc_want else ""), flush=True)
    t, last = None, ""
    deadline = time.time() + (15 if kind == "shots" else 25) * 60
    while time.time() < deadline:
        time.sleep(5)
        t = call("GET", "/jobs/%s" % jid)
        if t["status"] != last:
            last = t["status"]
            print("model view: %s" % last, flush=True)
        if last in ("done", "failed", "expired", "cancelled"):
            break
    if t is None or t["status"] in ("queued", "running"):
        call("POST", "/jobs/%s/cancel" % jid)
        die(1, "the team PC did not finish in time")
    call("POST", "/jobs/%s/reported" % jid)
    if t["status"] != "done":
        die(1, "the job %s (%s)" % (t["status"], t.get("error") or (t.get("result") or {}).get("error") or "no reason given"))
    got = 0
    for f in t.get("files") or []:
        if not (isinstance(f, dict) and isinstance(f.get("path"), str) and os.path.isfile(f["path"])):
            continue
        dst = os.path.join(out, os.path.basename(f["path"]))
        shutil.copyfile(f["path"], dst)
        got += 1
        print("model view: " + dst, flush=True)
        if dst.endswith(".mp4"):
            secs = 0.0
            try:
                secs = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", dst], capture_output=True, text=True, timeout=60).stdout.strip() or 0)
            except Exception:
                pass
            if secs > 0:
                sheet = dst[:-4] + "-sheet.jpg"
                subprocess.run(["nice", "-n", "10", "ffmpeg", "-loglevel", "error", "-y", "-i", dst, "-vf", "fps=8/%.3f,scale=480:-2,tile=4x2" % secs, "-frames:v", "1", sheet], timeout=300)
                if os.path.isfile(sheet):
                    print("model view: " + sheet, flush=True)
    if not got:
        die(1, "the job finished without pictures or videos")
    code = 0
finally:
    if mv:
        shutil.rmtree(os.path.join(root, mv), ignore_errors=True)
    if os.path.basename(build).startswith(".viewer."):   # the build of a checkout with changes is not remembered
        os.remove(build)
sys.exit(code)
PY
