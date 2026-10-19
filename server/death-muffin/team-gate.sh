#!/usr/bin/env bash
# The pre-release check (ROADMAP Phase 1, the team app: "the crash and install checks as a gate before a release goes live"; DECISIONS B61). publish-godot-client.sh
# runs it after the boot smoke and before the switch to the new build: a team PC downloads the release's own Windows files, starts the game to its first screen
# and quits it while it loads (the `install` and `quit-loading` steps of the release job, about 10 seconds of the PC's time). A step that fails on the PC stops
# the publish; no PC that can take it, no answer in time or a job the PC gave up lets it go on (the release checks after it is live still run).
#
#   team-gate.sh <stage folder> <version> <rev>
#
# 1. Asks the backend for the team PCs (GET /internal/team/pcs) and the jobs running now (GET /internal/team/jobs?status=running), and keeps the PCs that can take
#    a job soon: seen in the last 90 seconds, not paused, Death Muffin not running, not on battery, and not running a release or bench job (those hold a PC for
#    up to 40 minutes). None: "skipped", nothing is queued and nothing is waited for.
# 2. Hard-links DeathMuffin.exe, DeathMuffin.pck, the combat core's DLL and (when the build has one) DeathMuffin.assets.pck from the stage folder into
#    <team root>/gate-<24 random hex>/ (a copy where a link is not possible).
# 3. Queues ONE `release` job for whichever team PC takes it first (no target PC): title "Pre-release check of <version>", weight 60, time to live 15 minutes,
#    payload { version, rev, godotVersion, builds: [{ label: "release", files: [{ name, url, sha256, bytes, cacheKey? }] }], steps: ["install", "quit-loading"],
#    args: [] } (the shape teamapp/windows/JobPlan.cs ParseRelease reads; the exe and the art pack carry the same cacheKeys as team-release.sh's, so a PC keeps them).
# 4. Waits for a claim (DM_GATE_CLAIM_S, 150 seconds: a PC that runs without asking or in AFK mode takes it within seconds) and then for the end (DM_GATE_RUN_S,
#    420 seconds, which covers a new 500 MB art pack), reading the job every DM_GATE_POLL_S seconds (3).
# 5. The verdict, one line: done with every step passed: "passed", exit 0. A step where the game itself failed (the app's error begins "The game ": it did not
#    reach its first screen, stopped with an error code, never said BOOT OK, did not quit, or left a crash report): "FAILED" with the step's error and the PC's
#    graphics card, exit 10 (the only code that stops the publish). A step that failed for another reason (the download) is no verdict. Not claimed in time, out of time, or the job failed, was cancelled or expired without step results:
#    "no verdict", exit 0. Any failure of this script itself (the backend, the secret, the files) prints a line and exits 0: the gate never stops a release
#    for its own trouble. Whatever the verdict, a job still queued or running is cancelled, the job is marked reported (it is never posted to #build-alerts:
#    only live builds are, ops/team-report.sh) and the folder is removed.
# Env (tests override): DM_TEAM_ROOT (/var/www/death-muffin/team-files), DM_TEAM_URL (https://muffindevelopment.com/death-muffin/team-files), DM_TEAM_API
#      (http://127.0.0.1:5190), DM_TEAM_SECRET_FILE (/home/ubuntu/death-muffin/discord-agent/secret), DM_GATE_CLAIM_S, DM_GATE_RUN_S, DM_GATE_POLL_S.
set -uo pipefail
[ $# -eq 3 ] || { echo "usage: $0 <stage folder> <version> <rev>" >&2; exit 2; }
command -v python3 >/dev/null || { echo "pre-release check: python3 is missing: skipped"; exit 0; }
exec python3 - "$@" <<'PY'
import calendar, hashlib, json, os, re, secrets, shutil, signal, sys, time, urllib.error, urllib.request

stage, version, rev = sys.argv[1:4]
env = os.environ.get
root = env("DM_TEAM_ROOT") or "/var/www/death-muffin/team-files"
base_url = env("DM_TEAM_URL") or "https://muffindevelopment.com/death-muffin/team-files"
api = env("DM_TEAM_API") or "http://127.0.0.1:5190"
secret_file = env("DM_TEAM_SECRET_FILE") or "/home/ubuntu/death-muffin/discord-agent/secret"
claim_s = float(env("DM_GATE_CLAIM_S") or 150)
run_s = float(env("DM_GATE_RUN_S") or 420)
poll_s = float(env("DM_GATE_POLL_S") or 3)

DLL = "libdmcore.windows.template_release.x86_64.dll"
NEEDED = ["DeathMuffin.exe", "DeathMuffin.pck", DLL]
OPTIONAL = ["DeathMuffin.assets.pck"]
STEPS = ["install", "quit-loading"]
GODOT_VERSION = "4.7.2.stable"   # as team-release.sh
TITLE = "Pre-release check of %s"
WEIGHT_S = 60
TTL_S = 900
SEEN_S = 90            # a PC checks in every 30 s
LONG_KINDS = ("release", "bench")   # a PC running one of these is not free for minutes
FAILED = 10            # the one exit code that stops the publish
GAME_FAILED = "The game "   # how the app's boot steps begin every failure of the game itself (JobRunner.cs StepBootAsync); a download that failed is not one
START = time.monotonic()
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def say(message):
    print("pre-release check: " + message, flush=True)


def took():
    return "%d s" % round(time.monotonic() - START)


def call(secret, method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(api.rstrip("/") + path, data=data, method=method,
                                     headers={"X-Team-Secret": secret, "Content-Type": "application/json"})
    try:
        with OPENER.open(request, timeout=15) as r:
            answer = json.load(r)
    except urllib.error.HTTPError as e:
        try:
            why = json.load(e).get("error", "")
        except Exception:
            why = ""
        raise RuntimeError("the backend answered %d%s" % (e.code, (": " + why) if why else ""))
    except Exception as e:
        raise RuntimeError("the backend could not be reached (%s)" % (getattr(e, "reason", None) or e))
    if not isinstance(answer, dict) or not answer.get("success"):
        raise RuntimeError("the backend did not accept it")
    return answer.get("data") or {}


def seconds_ago(iso):
    try:
        return time.time() - calendar.timegm(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return float("inf")


def free_pcs(secret):
    """The PCs that can take a job soon, and a word on each PC left out (for the skipped line)."""
    pcs = call(secret, "GET", "/internal/team/pcs").get("pcs") or []
    running = call(secret, "GET", "/internal/team/jobs?status=running&limit=50").get("jobs") or []
    held = {j.get("claimedPc"): j.get("title") or j.get("kind") for j in running if isinstance(j, dict) and j.get("kind") in LONG_KINDS}
    free, why = [], []
    for pc in pcs:
        if not isinstance(pc, dict) or not isinstance(pc.get("pcId"), str):
            continue
        state = pc.get("state") if isinstance(pc.get("state"), dict) else {}
        name = pc.get("gpu") or pc.get("name") or pc["pcId"][:8]
        if seconds_ago(str(pc.get("lastSeen", ""))) > SEEN_S:
            why.append("%s not seen lately" % name)
        elif state.get("paused"):
            why.append("%s paused" % name)
        elif state.get("gameRunning"):
            why.append("%s playing Death Muffin" % name)
        elif state.get("onBattery"):
            why.append("%s on battery" % name)
        elif pc["pcId"] in held:
            why.append("%s busy with %s" % (name, held[pc["pcId"]]))
        else:
            free.append(pc)
    return free, why


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def stage_files(dest, folder):
    names = NEEDED + [n for n in OPTIONAL if os.path.isfile(os.path.join(stage, n))]
    files = []
    for n in names:
        src, dst = os.path.join(stage, n), os.path.join(dest, n)
        if os.path.islink(src) or not os.path.isfile(src):
            raise RuntimeError("the build has no %s" % n)
        try:
            os.link(src, dst)
        except OSError:
            shutil.copyfile(src, dst)
            os.chmod(dst, 0o644)
        sha = sha256_of(dst)
        entry = {"name": n, "url": "%s/%s/%s" % (base_url.rstrip("/"), folder, n), "sha256": sha, "bytes": os.path.getsize(dst)}
        if n == "DeathMuffin.exe":
            entry["cacheKey"] = "godot-release-" + sha[:16]
        if n == "DeathMuffin.assets.pck":
            entry["cacheKey"] = "assets-" + sha[:16]
        files.append(entry)
    return files


def verdict(job, gpu):
    """(exit code, line) for a job that has ended."""
    status = job.get("status")
    result = job.get("result") if isinstance(job.get("result"), dict) else {}
    steps = [s for s in (result.get("steps") or []) if isinstance(s, dict)]
    failed = [s for s in steps if s.get("ok") is False and str(s.get("error") or "").startswith(GAME_FAILED)]
    if failed:
        return FAILED, "FAILED on %s: %s (job %s)" % (gpu, "; ".join("%s: %s" % (s.get("step"), s.get("error") or "failed") for s in failed), job.get("id"))
    if status == "done" and sorted(s.get("step") for s in steps if s.get("ok") is True) == sorted(STEPS):
        return 0, "passed on %s: the game started and quit while loading cleanly (job %s, %s)" % (gpu, job.get("id"), took())
    return 0, "no verdict: the job %s %s%s; publishing without it" % (job.get("id"), status, (" (" + str(job.get("error"))[:160] + ")") if job.get("error") else "")


def main():
    try:
        with open(secret_file) as f:
            secret = f.read().strip()
    except OSError as e:
        say("cannot read the runner's secret (%s): skipped" % e.strerror)
        return 0
    try:
        free, why = free_pcs(secret)
    except RuntimeError as e:
        say("could not ask for the team PCs (%s): skipped" % e)
        return 0
    if not free:
        say("no team PC can take it now%s: skipped" % ((" (" + ", ".join(why) + ")") if why else ""))
        return 0
    if not os.path.isdir(root) or os.path.islink(root):
        say("the team-files folder %s is missing: skipped" % root)
        return 0
    gpus = {pc["pcId"]: pc.get("gpu") or "a team PC" for pc in free}
    folder = "gate-" + secrets.token_hex(12)
    dest = os.path.join(root, folder)
    job_id = None
    try:
        try:
            os.mkdir(dest, 0o755)
            os.chmod(dest, 0o755)
            files = stage_files(dest, folder)
        except (OSError, RuntimeError) as e:
            say("could not put the build's files in %s (%s): skipped" % (folder, getattr(e, "strerror", None) or e))
            return 0
        payload = {"version": version, "rev": rev, "godotVersion": GODOT_VERSION, "builds": [{"label": "release", "files": files}], "steps": STEPS, "args": []}
        job = {"kind": "release", "title": TITLE % version, "weightS": WEIGHT_S, "ttlS": TTL_S, "payload": payload}
        try:
            job_id = call(secret, "POST", "/internal/team/jobs", job).get("id")
        except RuntimeError as e:
            say("could not queue it (%s): skipped" % e)
            return 0
        say("queued job %s for %s; waiting up to %d s for a PC to take it" % (job_id, " or ".join(sorted(set(gpus.values()))), claim_s))
        claimed_at = None
        last = {}
        while True:
            time.sleep(poll_s)
            try:
                last = call(secret, "GET", "/internal/team/jobs/%s" % job_id)
            except RuntimeError as e:
                last = last or {}
                say("could not read the job (%s)" % e)
            status = last.get("status")
            if status in ("done", "failed", "cancelled", "expired"):
                code, line = verdict(last, gpus.get(last.get("claimedPc"), "a team PC"))
                say(line)
                return code
            now = time.monotonic()
            if status == "running" and claimed_at is None:
                claimed_at = now
                say("taken by %s after %s" % (gpus.get(last.get("claimedPc"), "a team PC"), took()))
            if claimed_at is None and now - START > claim_s:
                say("no verdict: no team PC took it within %d s; publishing without it" % claim_s)
                return 0
            if claimed_at is not None and now - claimed_at > run_s:
                say("no verdict: the PC did not finish within %d s; publishing without it" % run_s)
                return 0
    finally:
        if job_id:
            try:
                call(secret, "POST", "/internal/team/jobs/%s/cancel" % job_id)
            except RuntimeError:
                pass   # it had finished: nothing to cancel
            try:
                call(secret, "POST", "/internal/team/jobs/%s/reported" % job_id)
            except RuntimeError:
                pass
        shutil.rmtree(dest, ignore_errors=True)


def stop(signum, frame):
    raise SystemExit(0)   # the publish's timeout: the finally clause cancels the job and removes the folder; no verdict


signal.signal(signal.SIGTERM, stop)
try:
    code = main()
except SystemExit:
    raise
except Exception as e:   # the gate's own bug never stops a release
    say("the check broke (%s): skipped" % e)
    code = 0
sys.exit(code)
PY
