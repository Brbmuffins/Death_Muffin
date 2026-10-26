#!/usr/bin/env bash
# 3D models from a concept picture, made on a team PC (teamapp/README.md "The model job", ASSET_PIPELINE.md "Image to model"): ComfyUI's Pixal3D / TRELLIS.2 image-to-model
# workflow on the PC's graphics card (12 GB or more, ComfyUI Desktop installed: the PC's heartbeat says state.models), the face count set before the model is painted.
#
#   model-gen.sh [--pc <name or user>] [--model pixal3d|trellis2|both] [--faces N] [--texture 512|1024|2048|4096] [--seeds 0,1,...] [--runs <runs.json>] [--wait MINUTES]
#                <out dir> <picture> [<picture> ...]
#
# <picture>: a .png, .jpg or .webp of at most 32 MB (one subject; ComfyUI removes the background). The runs: every picture with every model and every seed (default: Pixal3D,
# 5000 faces, texture 1024, seed 0), each labelled <picture>-<model>[-s<seed>]; or --runs, a JSON list of { label, image (a picture's file name), model, faces, texture, seed }.
# At most 8 runs a job. A seed is added to the template's own seeds (0 keeps them), so the same seed gives the same model again.
# 1. The pictures: copied into <team root>/model-<24 hex>/ (removed at the end; team-files-prune.sh takes one a killed run left).
# 2. ONE `model` job, for the PC named by --pc (its name or its user's; default: any PC that runs model jobs), time to live 12 hours (a PC whose player is in the game takes
#    it later), waited for (--wait, default 12 hours and 30 minutes a run), then marked reported (nothing is posted anywhere).
# 3. The models copied to <out dir> as <label>.glb, and the PC's log of the job as <out dir>/<job id>.log (each run's settings, ComfyUI's version and card, why a run failed).
# Exit: 0 at least one model is in <out dir> (a run that failed is in the log), 1 the job failed, timed out or no PC can run it, 2 a usage or picture problem.
# Env: DM_TEAM_ROOT (/var/www/death-muffin/team-files), DM_TEAM_URL (https://muffindevelopment.com/death-muffin/team-files), DM_TEAM_API (http://127.0.0.1:5190),
#      DM_TEAM_SECRET_FILE (/home/ubuntu/death-muffin/discord-agent/secret), DM_TEAM_POLL_S (10).
set -uo pipefail
command -v python3 >/dev/null || { echo "model gen: python3 is required" >&2; exit 2; }
exec python3 - "$@" <<'PY'
import argparse, hashlib, json, os, re, secrets, shutil, sys, time, urllib.request

env = os.environ.get
root = env("DM_TEAM_ROOT") or "/var/www/death-muffin/team-files"
base_url = (env("DM_TEAM_URL") or "https://muffindevelopment.com/death-muffin/team-files").rstrip("/")
api = (env("DM_TEAM_API") or "http://127.0.0.1:5190").rstrip("/")
secret_file = env("DM_TEAM_SECRET_FILE") or "/home/ubuntu/death-muffin/discord-agent/secret"
poll_s = float(env("DM_TEAM_POLL_S") or 10)
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
MODELS = ("pixal3d", "trellis2")
TEXTURES = (512, 1024, 2048, 4096)
FACES_MIN, FACES_MAX, SEED_MAX, RUNS_MAX = 500, 200000, 1000000, 8          # teamapp/windows/Comfy.cs ComfyRules
PICTURE_MAX = 32 * 1024 * 1024                                              # teamapp/windows/JobPlan.cs MaxModelImageBytes
LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,23}$")                         # JobPlan.cs VariantLabelRe: the model is <label>.glb
PICTURE_TYPES = (".png", ".jpg", ".jpeg", ".webp")
TTL_S = 12 * 3600
RUN_S = 420                                                                 # about how long one run holds the card (a 4070 SUPER: 4 to 7 minutes)


def die(code, message):
    print("model gen: " + message, file=sys.stderr, flush=True)
    sys.exit(code)


def call(method, path, body=None):
    req = urllib.request.Request(api + "/internal/team" + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"content-type": "application/json", "x-team-secret": secret})
    with OPENER.open(req, timeout=20) as r:
        j = json.loads(r.read().decode())
    if not j.get("success"):
        raise RuntimeError(j.get("error") or "the backend refused")
    return j.get("data")


def slug(text, cut):
    s = re.sub(r"-+", "-", re.sub(r"[^a-z0-9-]+", "-", text.lower())).strip("-")
    return s[:cut].strip("-") or "picture"


ap = argparse.ArgumentParser(prog="model-gen.sh", description="3D models from concept pictures on a team PC (ComfyUI)")
ap.add_argument("--pc", default="")
ap.add_argument("--model", default="pixal3d", choices=MODELS + ("both",))
ap.add_argument("--faces", type=int, default=5000)
ap.add_argument("--texture", type=int, default=1024, choices=TEXTURES)
ap.add_argument("--seeds", default="0")
ap.add_argument("--runs", default="")
ap.add_argument("--wait", type=float, default=0, help="minutes to wait for the job (default 12 hours and 30 minutes a run)")
ap.add_argument("out")
ap.add_argument("pictures", nargs="+")
a = ap.parse_args()
secret = open(secret_file).read().strip()

# ---- the pictures (their names on the PC: the file name made safe)
pictures = {}   # name on the PC -> path here
by_given = {}   # the file name given -> name on the PC
for p in a.pictures:
    ext = os.path.splitext(p)[1].lower()
    if ext not in PICTURE_TYPES or not os.path.isfile(p) or os.path.islink(p) or not 0 < os.path.getsize(p) <= PICTURE_MAX:
        die(2, "%s: a picture is a real .png, .jpg or .webp file of at most 32 MB" % p)
    name = slug(os.path.splitext(os.path.basename(p))[0], 40) + (".jpg" if ext == ".jpeg" else ext)
    if name in pictures:
        die(2, "two pictures would both be called %s on the PC: rename one" % name)
    pictures[name] = p
    by_given[os.path.basename(p)] = name

# ---- the runs
if a.runs:
    try:
        runs = json.load(open(a.runs))
    except Exception as e:
        die(2, "the runs file is not JSON (%s)" % e)
    if not isinstance(runs, list) or not all(isinstance(r, dict) for r in runs):
        die(2, "the runs file is a list of { label, image, model, faces, texture, seed }")
    for r in runs:
        r["image"] = by_given.get(str(r.get("image", "")), str(r.get("image", "")))
else:
    try:
        seeds = [int(s) for s in a.seeds.split(",") if s.strip()]
    except ValueError:
        die(2, "--seeds is a list of whole numbers (0,1,2)")
    models = MODELS if a.model == "both" else (a.model,)
    runs = []
    for name in pictures:
        for m in models:
            for s in seeds or [0]:
                tail = "-" + m + ("-s%d" % s if len(seeds) > 1 or s else "")
                runs.append({"label": slug(os.path.splitext(name)[0], 24 - len(tail)) + tail, "image": name, "model": m, "faces": a.faces, "texture": a.texture, "seed": s})
if not 1 <= len(runs) <= RUNS_MAX:
    die(2, "a job has 1 to %d runs (this one would have %d): fewer pictures, models or seeds" % (RUNS_MAX, len(runs)))
labels = set()
for r in runs:
    label = str(r.get("label", ""))
    if not LABEL_RE.match(label) or label in labels:
        die(2, "run label %r: lowercase letters, digits and -, at most 24, each once" % label)
    labels.add(label)
    if r.get("image") not in pictures:
        die(2, "run %s names a picture that was not given: %s" % (label, r.get("image")))
    if r.get("model") not in MODELS:
        die(2, "run %s: the model is pixal3d or trellis2" % label)
    if not isinstance(r.get("faces"), int) or not FACES_MIN <= r["faces"] <= FACES_MAX:
        die(2, "run %s: faces from %d to %d" % (label, FACES_MIN, FACES_MAX))
    if r.get("texture") not in TEXTURES:
        die(2, "run %s: texture is one of %s" % (label, ", ".join(map(str, TEXTURES))))
    r.setdefault("seed", 0)
    if not isinstance(r["seed"], int) or not 0 <= r["seed"] <= SEED_MAX:
        die(2, "run %s: seed from 0 to %d" % (label, SEED_MAX))

# ---- a PC that runs model jobs
try:
    pcs = (call("GET", "/pcs?days=14") or {}).get("pcs", [])
except Exception as e:
    die(1, "the backend did not answer (%s)" % e)
able = [p for p in pcs if isinstance(p.get("state"), dict) and p["state"].get("models") is True]
def who(p):
    st = p.get("state") if isinstance(p.get("state"), dict) else {}
    why = st.get("modelsWhy") if st.get("models") is not True and isinstance(st.get("modelsWhy"), str) and st.get("modelsWhy") else ""
    return "%s (%s, %s, %.1f GB, app %s%s)" % (p.get("name"), p.get("username"), p.get("gpu") or "?", (st.get("vramMb") or 0) / 1024, p.get("version"), ": " + why if why else "")
target = None
if a.pc:
    hit = [p for p in pcs if a.pc.lower() in (str(p.get("name", "")).lower(), str(p.get("username", "")).lower())]
    if not hit:
        die(1, "no team PC called %s was seen in the last 14 days (seen: %s)" % (a.pc, "; ".join(map(who, pcs)) or "none"))
    if hit[0] not in able:
        die(1, "%s runs no model jobs: it needs a graphics card with 12 GB or more, ComfyUI Desktop and team app 0.5.0 or later (%s)" % (a.pc, who(hit[0])))
    target = hit[0]["pcId"]
elif not able:
    die(1, "no team PC runs model jobs: one needs a graphics card with 12 GB or more, ComfyUI Desktop and team app 0.5.0 or later (seen: %s)" % ("; ".join(map(who, pcs)) or "none"))

os.makedirs(a.out, exist_ok=True)
folder = "model-" + secrets.token_hex(12)
os.makedirs(os.path.join(root, folder), mode=0o755)
code = 1
try:
    files = []
    for name, p in pictures.items():
        dst = os.path.join(root, folder, name)
        shutil.copyfile(p, dst)
        os.chmod(dst, 0o644)
        data = open(dst, "rb").read()
        files.append({"name": name, "url": "%s/%s/%s" % (base_url, folder, name), "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
    minutes = max(1, round((120 + RUN_S * len(runs)) / 60))
    job = {"kind": "model", "title": "3D models from a picture: %d run%s, about %d minutes" % (len(runs), "" if len(runs) == 1 else "s", minutes),
           "weightS": 120 + RUN_S * len(runs), "ttlS": TTL_S, "payload": {"files": files, "runs": runs}}
    if target:
        job["targetPc"] = target
    jid = call("POST", "/jobs", job)["id"]
    print("model gen: job %s queued, %d run(s)%s: %s" % (jid, len(runs), " for " + a.pc if a.pc else "", ", ".join(r["label"] for r in runs)), flush=True)
    t, last = None, ""
    deadline = time.time() + (a.wait * 60 if a.wait > 0 else TTL_S + 30 * 60 * len(runs))
    while time.time() < deadline:
        time.sleep(poll_s)
        try:
            t = call("GET", "/jobs/%s" % jid)
        except Exception as e:
            print("model gen: the backend did not answer (%s), trying again" % e, flush=True)
            continue
        if t["status"] != last:
            last = t["status"]
            print("model gen: %s" % last, flush=True)
        if last in ("done", "failed", "expired", "cancelled"):
            break
    if t is None or t["status"] in ("queued", "running"):
        call("POST", "/jobs/%s/cancel" % jid)
        die(1, "the team PC did not finish in time (job %s cancelled)" % jid)
    log = (t.get("result") or {}).get("log") if isinstance(t.get("result"), dict) else None
    if log:
        with open(os.path.join(a.out, jid + ".log"), "w") as f:
            f.write(log)
        print("model gen: " + os.path.join(a.out, jid + ".log"), flush=True)
    call("POST", "/jobs/%s/reported" % jid)
    if t["status"] != "done":
        die(1, "the job %s (%s)" % (t["status"], t.get("error") or "no reason given"))
    got = 0
    for f in t.get("files") or []:
        if isinstance(f, dict) and isinstance(f.get("path"), str) and f["path"].endswith(".glb") and os.path.isfile(f["path"]):
            dst = os.path.join(a.out, os.path.basename(f["path"]))
            shutil.copyfile(f["path"], dst)
            got += 1
            print("model gen: " + dst, flush=True)
    if not got:
        die(1, "the job finished without models")
    if got < len(runs):
        print("model gen: %d of %d runs made a model (the log says why the others did not)" % (got, len(runs)), flush=True)
    code = 0
finally:
    shutil.rmtree(os.path.join(root, folder), ignore_errors=True)
sys.exit(code)
PY
