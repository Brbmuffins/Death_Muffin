#!/usr/bin/env bash
# Team PC checks of a revision BEFORE it goes live (DECISIONS B62; ROADMAP Phase 1, the team app). Whoever ships asks: the Discord agent for a proposal (its
# thread gets the results), a session for its branch (the results go to a new thread or a DM: ask the person which). Nothing here posts anywhere, and nothing
# waits on it: approving a change never waits for its checks (Helix, 2026-10-19). The 14-second pre-release check inside the publish is separate (team-gate.sh).
#
#   team-check.sh <rev> [--checks install,quit-loading,screens,stutter,bench,soak] [--compare] [--pc <pc id>] [--out <dir>] [--soak-minutes N] [--max-wait MINUTES]
#
# --checks     the release checks' steps to run (default install,quit-loading). install, quit-loading and bench run the RELEASE build; screens, stutter and soak the
#              DEBUG build (the QA scenarios start only in a debug build).
# --compare    the same steps on the LIVE build first, on the same PC, so every line reads live -> this change ("before" is what players have now).
# --pc         the team PC that runs them (its id); default: a PC that can take a job soon (seen in the last 90 s, not paused, not in Death Muffin, not on battery, not
#              running a release or bench job), else the PC seen most recently in the last 14 days (it takes the jobs when it is free).
# --out        the results' folder (default $DM_TEAM_CHECKS/<rev12>-<UTC stamp>; $DM_TEAM_CHECKS keeps its newest 20).
#
# 1. Builds what the steps need: the release build through publish-godot-client.sh with EXPORT_ONLY (the revision's own prepare, import, export with baked shaders,
#    art pack and boot smoke; nothing published, no CI gate), the debug build through the revision's discord-agent/preview-godot.sh --team (a scratch worktree, nice 10).
#    The live build's release files are the live client's own (DM_TEAM_MANIFEST); its debug build is made from its revision the same way.
# 2. Puts the files in <team root>/check-<24 hex>/<live|change>/ (debug/ inside) and queues one `release` job per build, targeted at the chosen PC, live first:
#    title "Checks of <rev7>" / "Checks of the live build <version>", weight from the steps, time to live 4 hours, payload as the release checks always had
#    ({ version, rev, godotVersion, builds, steps, setups, screens, soak, args }: teamapp/windows/JobPlan.cs ParseRelease).
# 3. Waits for each (a claim within --max-wait minutes, default 120, then its run), and writes <out>/summary.md (a header, then per step a line for each build: ✓ or ✗
#    and the numbers), <out>/screens-<w>x<h>.png|jpg (contact sheets: a row per build and UI scale, a column per shot; Pillow) and <out>/result.json. Then it removes the
#    files' folder, cancels a job still open and marks the jobs reported.
# The last line on stdout: TEAMCHECK: {"status": "done"|"no-pc"|"timeout"|"failed"|"error", "why", "out", "summary", "sheets", "pc", "gpu", "jobs", "lines"}.
# Exit 0 when results were written (a failed step is in the summary), 1 when there are none (status and why say what happened), 2 for a usage error.
# Env (tests override): DM_TEAM_MANIFEST, DM_TEAM_ROOT, DM_TEAM_URL, DM_TEAM_API, DM_TEAM_SECRET_FILE, DM_TEAM_RESULTS, DM_TEAM_REPO, DM_TEAM_WORK, DM_TEAM_CHECKS,
#      DM_TEAM_PREVIEW (a preview-godot.sh other than the revision's own), DM_TEAM_PUBLISH (a publish-godot-client.sh other than this folder's), DM_TEAM_BUILD_TIMEOUT
#      (1500 s each build), DM_TEAM_NICE (10), DM_TEAM_POLL_S (10), SHEET_MAX_BYTES (5 MB).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null || { echo "team check: python3 is required" >&2; exit 1; }
exec python3 - "$HERE" "$@" <<'PY'
import argparse, calendar, hashlib, io, json, os, re, secrets, shutil, signal, stat, subprocess, sys, tempfile, time, urllib.error, urllib.request

here = sys.argv[1]
env = os.environ.get
manifest_path = env("DM_TEAM_MANIFEST") or "/var/www/death-muffin/client/manifest.json"
root = env("DM_TEAM_ROOT") or "/var/www/death-muffin/team-files"
base_url = env("DM_TEAM_URL") or "https://muffindevelopment.com/death-muffin/team-files"
api = env("DM_TEAM_API") or "http://127.0.0.1:5190"
secret_file = env("DM_TEAM_SECRET_FILE") or "/home/ubuntu/death-muffin/discord-agent/secret"
RESULTS = os.path.abspath(env("DM_TEAM_RESULTS") or "/home/ubuntu/death-muffin/team-results")
repo = env("DM_TEAM_REPO") or "/home/ubuntu/vps-handoffs/DeathMuffin/game"
work = env("DM_TEAM_WORK") or "/home/ubuntu/death-muffin/deploy"
checks_root = env("DM_TEAM_CHECKS") or "/home/ubuntu/death-muffin/team-checks"
preview_override = env("DM_TEAM_PREVIEW") or ""
publish_script = env("DM_TEAM_PUBLISH") or os.path.join(here, "publish-godot-client.sh")
build_timeout = int(env("DM_TEAM_BUILD_TIMEOUT") or 1500)
nice_level = env("DM_TEAM_NICE") or "10"
poll_s = float(env("DM_TEAM_POLL_S") or 10)

DLL = "libdmcore.windows.template_release.x86_64.dll"
RELEASE_FILES = ["DeathMuffin.exe", "DeathMuffin.pck", DLL]   # + DeathMuffin.assets.pck when the build has one
DEBUG_NEEDED = ["DeathMuffinDebug.exe", "DeathMuffinDebug.pck", DLL]
STEPS = ["install", "quit-loading", "screens", "stutter", "bench", "soak"]
NEEDS_DEBUG = ("screens", "stutter", "soak")
STEP_S = {"install": 30, "quit-loading": 30, "screens": 150, "stutter": 210, "bench": 240}   # about how long each step holds the PC (the soak: its minutes)
GODOT_VERSION = "4.7.2.stable"   # CLAUDE.md: Godot stays 4.7.2 until a deliberate, benchmarked upgrade
RESOLUTIONS = ["1920x1080", "2560x1440", "3840x2160", "3440x1440"]
SCREENS_PRESET = "high"
# The standard UI shots, in the format of client/main/qa_ui_shots.gd (the whole screen, not a window crop: the check is how the UI sits at each size and scale): the bag with
# an item card, the character sheet, the spellbook, the vault (it opens only in the Chapterhouse), the map and the HUD in the Hollow Graves. Names: lowercase, digits and "-".
SCREEN_PLAN = {"discipline": "gravecaller", "shots": [
    {"name": "bag-tooltip", "open": ["bag"], "hover": "item:staff_moon"},
    {"name": "character-sheet", "open": ["character"]},
    {"name": "spellbook", "open": ["spellbook"]},
    {"name": "vault", "open": ["vault"], "area": "chapterhouse"},
    {"name": "map", "open": ["map"]},
    {"name": "hud-fight", "area": "graves", "wait_ms": 4000, "fight": True},
]}
# The bench step: the Full Party fight in the Hollow Graves with a Gravecaller on Low and on Medium, Full length (the budgets' fight, CLAUDE.md).
SETUPS = [{"preset": preset, "room": "graves", "class": 2, "size": "full_party", "length": "full"} for preset in ("low", "medium")]
TTL_S = 4 * 3600
SEEN_S = 90
LONG_KINDS = ("release", "bench")
CHECKS_KEEP = 20
TITLES = {"install": "install", "quit-loading": "quit while loading", "screens": "screens", "stutter": "stutter", "bench": "bench", "soak": "soak"}
DISCIPLINES = {1: "Ossuary", 2: "Gravecaller", 3: "Mourner", 4: "Rotweaver", 11: "Reaper"}
PRESETS = ["low", "medium", "high", "ultra"]
JSON_MAX = 1024 * 1024
PNG_MAX = 8 * 1024 * 1024
SHEET_MAX = int(env("SHEET_MAX_BYTES") or 5 * 1024 * 1024)
SHEETS_MAX = 4
SHOT_ORDER = ("bag", "char", "spell", "vault", "map", "hud")
SHOT_RE = re.compile(r"^(\d{3,4})x(\d{3,4})(?:_s(\d+(?:-\d+)?))?_([a-z0-9][a-z0-9_-]*)\.png$")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f​-‏‪-‮⁦-⁩﻿]")
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # the backend is on this machine: never through a proxy from the environment
START = time.monotonic()


def say(message):
    print("team check: " + message, file=sys.stderr, flush=True)


def took(since):
    return "%d s" % round(time.monotonic() - since)


class Stop(Exception):
    """Ends the check with a status (no-pc, timeout, failed, error) and a reason in plain words."""
    def __init__(self, status, why):
        super().__init__(why)
        self.status = status


def call(secret, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else (b"" if method == "POST" else None)
    request = urllib.request.Request(api.rstrip("/") + path, data=data, method=method, headers={"X-Team-Secret": secret, "Content-Type": "application/json"})
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


def git(*args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    try:
        proc.wait(10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.wait()


def run_group(cmd, cwd, child_env, timeout):
    """(exit code or None on a timeout, output) of a command in its own process group, stopped whole at the timeout."""
    log = tempfile.TemporaryFile()
    proc = subprocess.Popen(cmd, cwd=cwd, env=child_env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        proc.wait(timeout)
    except subprocess.TimeoutExpired:
        kill_group(proc)
        log.close()
        return None, ""
    finally:
        if proc.poll() is None:
            kill_group(proc)
    log.seek(0)
    out = log.read().decode("utf-8", "replace")
    log.close()
    return proc.returncode, out


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def link_or_copy(src, dst):
    try:
        os.link(src, dst)
    except OSError:
        shutil.copyfile(src, dst)
        os.chmod(dst, 0o644)


# ── the builds ───────────────────────────────────────────────────────────────────────────────────────────────────────

def build_release(rev, dest):
    """The release build of `rev` (publish-godot-client.sh EXPORT_ONLY) into `dest`; raises Stop on a failure."""
    began = time.monotonic()
    say("building the release export of %s (EXPORT_ONLY, nice %s, at most %d s)" % (rev[:12], nice_level, build_timeout))
    child_env = dict(os.environ, EXPORT_ONLY=dest, REPO=repo)
    code, out = run_group(["nice", "-n", nice_level, "bash", publish_script, rev], work, child_env, build_timeout)
    if code is None:
        raise Stop("error", "the release export of %s took longer than %d s and was stopped" % (rev[:12], build_timeout))
    missing = [n for n in RELEASE_FILES if not os.path.isfile(os.path.join(dest, n))]
    if code != 0 or missing:
        tail = " ".join(l.strip() for l in out.strip().splitlines()[-2:])[:240]
        raise Stop("error", "the release export of %s failed (exit %s)%s" % (rev[:12], code, ": " + tail if tail else ""))
    say("the release export is ready (%s)" % took(began))


def build_debug(rev, dest):
    """The debug build of `rev` (its preview-godot.sh --team in a scratch worktree) moved to <dest>/debug; returns its file entries; raises Stop on a failure."""
    began = time.monotonic()
    if git("cat-file", "-e", rev + "^{commit}").returncode != 0:
        raise Stop("error", "the checkout %s does not have revision %s" % (repo, rev[:12]))
    wt = os.path.join(work, "team-check-wt-%s-%s" % (rev[:12], secrets.token_hex(3)))
    preview_dir = None
    try:
        os.makedirs(work, exist_ok=True)
        added = git("worktree", "add", "-q", "--detach", wt, rev)
        if added.returncode != 0:
            raise Stop("error", "could not make a worktree of %s (%s)" % (rev[:12], (added.stderr.strip().splitlines() or ["git failed"])[-1]))
        script = preview_override or os.path.join(wt, "server/death-muffin/discord-agent/preview-godot.sh")
        try:
            with open(script) as f:
                has_team = "--team" in f.read()
        except OSError:
            has_team = False
        if not has_team:
            raise Stop("error", "the preview-godot.sh of %s has no --team (an older revision): its screens, stutter and soak cannot run" % rev[:12])
        say("building the debug export of %s (preview-godot.sh --team, nice %s, at most %d s)" % (rev[:12], nice_level, build_timeout))
        child_env = dict(os.environ, DM_TEAM_ROOT=root, DM_TEAM_URL=base_url, CLIENT_MANIFEST=manifest_path)
        prep = os.path.join(wt, "tools/check/prep.sh")   # the revision's own setup script: preview-godot.sh looks beside itself, where only the agent's installed copy has one
        if "DM_PREP" not in child_env and os.path.isfile(prep):
            child_env["DM_PREP"] = prep
        code, output = run_group(["nice", "-n", nice_level, "bash", script, secrets.token_hex(3), "--team"], wt, child_env, build_timeout)
        if code is None:
            raise Stop("error", "the debug export of %s took longer than %d s and was stopped" % (rev[:12], build_timeout))
        lines = [l for l in output.splitlines() if l.strip()]
        line = next((l for l in reversed(lines) if l.startswith("TEAMFILES: ")), None)
        try:
            built = json.loads(line[len("TEAMFILES: "):]) if line else None
        except ValueError:
            built = None
        if line and isinstance(built, list) and built and isinstance(built[0], dict):
            m = re.search(r"/([0-9a-f]{32})/[^/]+$", str(built[0].get("url", "")))
            preview_dir = os.path.join(root, m.group(1)) if m else None
        if code != 0 or not isinstance(built, list) or not built or not preview_dir:
            tail = " ".join(l.strip() for l in lines[-2:])[:200]
            raise Stop("error", "the debug export of %s failed (exit %s)%s" % (rev[:12], code, ": " + tail if tail else ""))
        if os.path.islink(preview_dir) or not os.path.isdir(preview_dir):
            raise Stop("error", "the debug export's folder %s is missing" % os.path.basename(preview_dir))
        entries = []
        for e in built:
            name = e.get("name") if isinstance(e, dict) else None
            path = os.path.join(preview_dir, name) if isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9._-]{1,80}", name) else None
            if not path or os.path.islink(path) or not os.path.isfile(path) or os.path.getsize(path) != e.get("bytes") or not re.fullmatch(r"[0-9a-f]{64}", str(e.get("sha256", ""))):
                raise Stop("error", "the debug export's file list does not match its folder (%s)" % (name,))
            entries.append({"name": name, "sha256": e["sha256"], "bytes": e["bytes"], **({"cacheKey": e["cacheKey"]} if e.get("cacheKey") else {})})
        missing = [n for n in DEBUG_NEEDED if n not in [x["name"] for x in entries]]
        if missing:
            raise Stop("error", "the debug export has no %s" % ", ".join(missing))
        os.rename(preview_dir, os.path.join(dest, "debug"))
        preview_dir = None
        say("the debug export is ready (%s)" % took(began))
        return entries
    finally:
        if preview_dir:
            shutil.rmtree(preview_dir, ignore_errors=True)
        git("worktree", "remove", "--force", wt)
        shutil.rmtree(wt, ignore_errors=True)
        git("worktree", "prune")


def release_entries(folder):
    """The release build's payload entries from the files in `folder` (the exe and the art pack with the release checks' cache keys)."""
    out = []
    for n in RELEASE_FILES + ["DeathMuffin.assets.pck"]:
        p = os.path.join(folder, n)
        if not os.path.isfile(p):
            continue
        sha = sha256_of(p)
        e = {"name": n, "sha256": sha, "bytes": os.path.getsize(p)}
        if n == "DeathMuffin.exe":
            e["cacheKey"] = "godot-release-" + sha[:16]
        if n == "DeathMuffin.assets.pck":
            e["cacheKey"] = "assets-" + sha[:16]
        out.append(e)
    return out


def with_urls(entries, rel):
    return [dict(e, url="%s/%s/%s" % (base_url.rstrip("/"), rel, e["name"])) for e in entries]


# ── the PC ───────────────────────────────────────────────────────────────────────────────────────────────────────────

def seconds_ago(iso):
    try:
        return time.time() - calendar.timegm(time.strptime(str(iso)[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return float("inf")


def choose_pc(secret, wanted):
    """The PC row that runs the checks: --pc, else one free soon, else the one seen most recently in 14 days; raises Stop("no-pc") when there is none."""
    pcs = [p for p in (call(secret, "GET", "/internal/team/pcs?days=14").get("pcs") or []) if isinstance(p, dict) and isinstance(p.get("pcId"), str)]
    if wanted:
        for p in pcs:
            if p["pcId"] == wanted:
                return p
        raise Stop("no-pc", "the team PC %s was not seen in the last 14 days" % wanted)
    if not pcs:
        raise Stop("no-pc", "no team PC was seen in the last 14 days")
    running = call(secret, "GET", "/internal/team/jobs?status=running&limit=50").get("jobs") or []
    held = {j.get("claimedPc") for j in running if isinstance(j, dict) and j.get("kind") in LONG_KINDS}
    for p in pcs:
        st = p.get("state") if isinstance(p.get("state"), dict) else {}
        if seconds_ago(p.get("lastSeen")) <= SEEN_S and not (st.get("paused") or st.get("gameRunning") or st.get("onBattery")) and p["pcId"] not in held:
            return p
    return sorted(pcs, key=lambda p: seconds_ago(p.get("lastSeen")))[0]


def pc_name(p):
    who = p.get("username") or ""
    return ("%s's PC" % who if who else (p.get("name") or "a team PC"))


# ── reading the results (the PC's own files: <team results>/<job id>/) ────────────────────────────────────────────────

def clean(value, limit=80, markdown=True):
    """Text from a PC or a result, safe in a Discord message: no control characters, markdown escaped (not for a picture's text), cut."""
    s = CONTROL.sub(" ", str(value if value is not None else "")).strip()
    s = re.sub(r"\s+", " ", s)[:limit]
    return re.sub(r"([\\*_`~|>@])", r"\\\1", s) if markdown else s


def number(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and value == value and abs(value) != float("inf") else None


def fmt(value, digits=1):
    v = number(value)
    if v is None:
        return None
    if abs(v) >= 100:
        return "{:,}".format(round(v))
    text = "%.*f" % (digits, v)
    return text.rstrip("0").rstrip(".") if "." in text else text


def signed(value):
    v = number(value)
    if v is None:
        return None
    return ("+" if v > 0 else "") + (fmt(v, 2) or "0")


def pick(*values):
    for v in values:
        if v is not None:
            return v
    return None


def file_path(job, name):
    """The path of result file `name`, only when it is directly in <team results>/<job id>/ and listed by the backend."""
    for f in job.get("files") or []:
        if isinstance(f, dict) and f.get("name") == name and isinstance(f.get("path"), str):
            p = os.path.abspath(f["path"])
            if os.path.dirname(p) == os.path.join(RESULTS, job["id"]) and os.path.basename(p) == name:
                return p
    return None


def read_file(job, name, limit):
    """The file's bytes: a regular file below the limit, opened without following a link; None when it is not there or not safe."""
    p = file_path(job, name)
    if not p:
        return None
    try:
        fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_size > limit:
            return None
        return fh.read(limit + 1)


def read_json(job, step):
    raw = read_file(job, step + ".json", JSON_MAX)
    if raw is None:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError:
        return None


def rows_of(data, *keys):
    """The list of dict rows in a result: the value itself, or the first of `keys` (or any list of dicts) in an object."""
    if isinstance(data, list):
        return [r for r in data if isinstance(r, dict)]
    if isinstance(data, dict):
        for k in keys:
            if isinstance(data.get(k), list):
                return [r for r in data[k] if isinstance(r, dict)]
        for v in data.values():
            if isinstance(v, list) and v and all(isinstance(r, dict) for r in v):
                return v
    return []


def detail_install(entry, data, ok):
    d = data if isinstance(data, dict) else {}
    ms = number(pick(d.get("bootMs"), d.get("boot_ms"), d.get("ms"), (entry or {}).get("ms")))   # the app's install.json has bootMs (the game's BOOT OK <ms>)
    return ["first screen after %s ms" % fmt(ms)] if ok and ms is not None else ([] if not ok else ["booted"])


def detail_quit(entry, data, ok):
    d = data if isinstance(data, dict) else {}
    seconds = number(d.get("seconds"))
    if seconds is None:
        ms = number(pick(d.get("ms"), (entry or {}).get("ms")))
        seconds = ms / 1000 if ms is not None else None
    if ok:
        return ["exits cleanly" + (" in %s s" % fmt(seconds) if seconds is not None else "")]
    return []


def detail_stutter(entry, data, ok):
    rites = [r for r in rows_of(data, "rows", "rites", "casts", "results") if number(r.get("worst_ms")) is not None]
    out = []
    if rites:
        worst = sorted(rites, key=lambda r: -number(r["worst_ms"]))[:3]
        names = []
        for r in worst:
            who = r.get("discipline")
            who = DISCIPLINES.get(who, who) if not isinstance(who, bool) else None
            if isinstance(who, str) and who.islower():
                who = who.capitalize()   # the game's stutter.json names them ("ossuary")
            rite = clean(str(r.get("rite", "?")).replace("_", " ").replace("-", " "), 40)
            names.append("%s%s %s ms" % (rite, " (%s)" % clean(who, 20) if who not in (None, "") else "", fmt(r["worst_ms"])))
        out.append("worst " + ", ".join(names))
        compiles = sum(number(r.get("compilations")) or 0 for r in rites)
        if compiles > 0:
            # the game's per-kind counts (qa_stutter.gd `kinds`): "specialization" compiles in the background, the other kinds make the frame wait
            background = [number(r["kinds"].get("specialization")) for r in rites if isinstance(r.get("kinds"), dict)]
            known = [b for b in background if b is not None]
            out.append("%s pipeline compiles%s" % (fmt(compiles, 0), " (%s in the background)" % fmt(sum(known), 0) if known else ""))
    d = data if isinstance(data, dict) else {}
    p50, p99 = number(pick(d.get("p50"), d.get("p50_ms"))), number(pick(d.get("p99"), d.get("p99_ms")))
    if p50 is not None or p99 is not None:
        out.append("p50 %s / p99 %s ms" % (fmt(p50) or "?", fmt(p99) or "?"))
    return out


def detail_bench(entry, data, ok):
    # the app's bench.json has `summary` (a flat row per run: preset, avg_fps, p99_ms, ...) and the `runs` themselves (the benchmark payloads, numbers under `metrics`)
    rows = [r for r in rows_of(data, "summary") if number(r.get("avg_fps")) is not None]
    if not rows:
        rows = [dict(r["metrics"], preset=r.get("preset")) for r in rows_of(data, "runs") if isinstance(r.get("metrics"), dict) and number(r["metrics"].get("avg_fps")) is not None]
    rows.sort(key=lambda r: PRESETS.index(r.get("preset")) if r.get("preset") in PRESETS else 9)
    out = []
    for r in rows:
        p99 = number(r.get("p99_ms"))
        out.append("%s %s fps%s" % (clean(str(r.get("preset", "?")).capitalize(), 12), fmt(r["avg_fps"]), " (p99 %s ms)" % fmt(p99) if p99 is not None else ""))
    return [" · ".join(out)] if out else []


def detail_soak(entry, data, ok, minutes, notes=None):
    d = data if isinstance(data, dict) else {}
    rows = rows_of(d, "minutes", "rows", "samples")
    growth = d.get("growth") if isinstance(d.get("growth"), dict) else {}
    parts = []
    for k, v in list(growth.items())[:5]:
        if isinstance(v, dict):
            v = pick(v.get("delta"), v.get("growth"), v.get("diff"))
        s = signed(v)
        if s is not None:
            parts.append("%s %s" % (clean(str(k).replace("_", " "), 30), s))
    head = "%s min" % (len(rows) or minutes or "?")
    out = [head + (", growth (last 5 min vs first 5): " + ", ".join(parts) if parts else "")]
    said = notes.get("notes") if isinstance(notes, dict) and isinstance(notes.get("notes"), list) else []
    if said:   # the app's soak-notes.json: what happened to the PC while it ran (a key, the mouse, other programs, the battery)
        out.append("PC notes (%d): %s" % (len(said), clean(said[0], 80)))
    return out


def screens_of(job):
    """[(width, height, scale, shot, name)] for the job's screen pictures."""
    out = []
    for f in job.get("files") or []:
        m = SHOT_RE.match(str(f.get("name", ""))) if isinstance(f, dict) else None
        if m:
            out.append((int(m.group(1)), int(m.group(2)), (m.group(3) or "").replace("-", "."), m.group(4), f["name"]))
    return out


def step_line(job, step):
    """(mark, text) for one step of a finished job: mark 'ok', 'bad' or 'none' (not run)."""
    result = job.get("result") if isinstance(job.get("result"), dict) else {}
    sent = {s.get("step"): s for s in result.get("steps", []) if isinstance(s, dict)}
    payload = job.get("payload") if isinstance(job.get("payload"), dict) else {}
    entry = sent.get(step)
    if entry and entry.get("skipped") is True:   # the PC left it out on purpose (a benchmark on a PC with benchmarks off, team app 0.4.4)
        return ("none", "– skipped" + (": " + clean(entry.get("error"), 120) if entry.get("error") else ""))
    data = read_json(job, step)
    ok = entry.get("ok") if entry and isinstance(entry.get("ok"), bool) else (data.get("ok") if isinstance(data, dict) and isinstance(data.get("ok"), bool) else None)
    if ok is None:
        why = clean(job.get("error"), 160) if job.get("status") != "done" and job.get("error") else ""
        return ("none", "– %s%s" % ("not reached" if job.get("status") != "done" else "no result", ": " + why if why else ""))
    try:
        if step == "install":
            parts = detail_install(entry, data, ok)
        elif step == "quit-loading":
            parts = detail_quit(entry, data, ok)
        elif step == "screens":
            shots = screens_of(job)
            sizes = len({(s[0], s[1]) for s in shots})
            parts = ["%d pictures at %d resolution%s" % (len(shots), sizes, "" if sizes == 1 else "s")] if shots else []
            note = data.get("note") if isinstance(data, dict) else None
            if note:
                parts.append(clean(note, 80))
        elif step == "stutter":
            parts = detail_stutter(entry, data, ok)
        elif step == "bench":
            parts = detail_bench(entry, data, ok)
        else:
            soak = payload.get("soak") if isinstance(payload.get("soak"), dict) else {}
            parts = detail_soak(entry, data, ok, soak.get("minutes"), read_json(job, "soak-notes"))
    except Exception:
        parts = ["(the result could not be read)"]
    if not ok:
        why = (entry or {}).get("error") or (data.get("error") if isinstance(data, dict) else None)
        parts.insert(0, clean(why, 160) if why else "failed")
    return ("ok" if ok else "bad", "%s %s" % ("✓" if ok else "✗", "; ".join(parts) if parts else "ok"))


# ── the contact sheets ───────────────────────────────────────────────────────────────────────────────────────────────

def font_of(size):
    from PIL import ImageFont
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default(size)


def shot_key(shot):
    for i, prefix in enumerate(SHOT_ORDER):
        if shot.startswith(prefix):
            return (i, shot)
    return (len(SHOT_ORDER), shot)


def contact_sheets(entries, title):
    """
    One contact sheet per resolution (at most SHEETS_MAX, the ones with most pictures): a row per build and UI scale, a column per shot. `entries` is a list of
    (row label, second line, job) in row order. Returns ([(file name, bytes)], notes).
    """
    by_res = {}
    for order, (label, sub, job) in enumerate(entries):
        for (w, h, scale, shot, name) in screens_of(job):
            by_res.setdefault((w, h), []).append((order, label, sub, scale, shot, job, name))
    if not by_res:
        return [], []
    from PIL import Image, ImageDraw   # (an ImportError here is the caller's note: no Pillow, no sheets)
    Image.MAX_IMAGE_PIXELS = 4096 * 4096
    wanted = sorted(sorted(by_res, key=lambda r: -len(by_res[r]))[:SHEETS_MAX], key=lambda r: (r[0] * r[1], r))
    sheets, notes = [], []
    for (w, h) in wanted:
        cells, heads = {}, {}   # (order, scale, shot) -> thumbnail; (order, scale) -> what its row says
        for order, label, sub, scale, shot, job, name in by_res[(w, h)]:
            raw = read_file(job, name, PNG_MAX)
            if raw is None:
                continue
            try:
                im = Image.open(io.BytesIO(raw)).convert("RGB")
                im = im.resize((480, max(1, int(480 * h / w + 0.5))), Image.LANCZOS)   # a PNG can be 4K: keep only what the sheet needs
            except Exception:
                continue
            cells[(order, scale, shot)] = im
            heads[(order, scale)] = (label, sub)
        if not cells:
            continue
        rows = sorted(heads, key=lambda k: (k[0], float(k[1] or 0)))   # the builds in order, the default scale first
        cols = sorted({k[2] for k in cells}, key=shot_key)
        built = None
        for tw in (360, 270, 200, 140):   # smaller until it fits
            th = max(1, int(tw * h / w + 0.5))
            pad, label_w, head_h = 8, 260, 56
            size = max(11, tw // 24)
            canvas = Image.new("RGB", (label_w + len(cols) * (tw + pad) + pad, head_h + len(rows) * (th + pad) + pad), (24, 24, 28))
            d = ImageDraw.Draw(canvas)
            small, big = font_of(size), font_of(18)
            d.text((pad, 8), "%dx%d  ·  %s" % (w, h, title), font=big, fill=(240, 240, 245))
            for ci, shot in enumerate(cols):
                d.text((label_w + ci * (tw + pad) + pad, head_h - 22), shot.replace("_", " ")[:28], font=small, fill=(190, 190, 200))
            for ri, key in enumerate(rows):
                y = head_h + ri * (th + pad)
                label, sub = heads[key]
                for li, (text, fill) in enumerate(((label[:30], (240, 240, 245)), (sub[:32], (160, 160, 170)), (("UI scale " + key[1]) if key[1] else "default UI scale", (160, 160, 170)))):
                    d.text((pad, y + 4 + li * (size + 6)), text, font=small, fill=fill)
                for ci, shot in enumerate(cols):
                    x = label_w + ci * (tw + pad) + pad
                    im = cells.get((key[0], key[1], shot))
                    if im is None:
                        d.rectangle((x, y, x + tw - 1, y + th - 1), fill=(46, 46, 52))
                        d.text((x + tw // 2 - 4, y + th // 2 - size // 2), "–", font=small, fill=(110, 110, 120))
                    else:
                        canvas.paste(im.resize((tw, th), Image.LANCZOS), (x, y))
            for ext, kind in (("png", "PNG"), ("jpg", "JPEG")):
                buf = io.BytesIO()
                canvas.save(buf, kind, **({"quality": 86} if kind == "JPEG" else {}))
                if buf.tell() <= SHEET_MAX:
                    built = ("screens-%dx%d.%s" % (w, h, ext), buf.getvalue())
                    break
            if built:
                break
        if built:
            sheets.append(built)
        else:
            notes.append("the %dx%d sheet was too large to keep" % (w, h))
    return sheets, notes


# ── the check ────────────────────────────────────────────────────────────────────────────────────────────────────────

def payload_for(version, rev, steps, release, debug, soak_minutes):
    builds = []
    if release is not None:
        builds.append({"label": "release", "files": release})
    if debug is not None:
        builds.append({"label": "debug", "files": debug})
    p = {"version": version, "rev": rev, "godotVersion": GODOT_VERSION, "builds": builds, "steps": steps}
    if "bench" in steps:
        p["setups"] = SETUPS
    if "screens" in steps:
        p["screens"] = {"plan": SCREEN_PLAN, "resolutions": RESOLUTIONS, "preset": SCREENS_PRESET}
    if "soak" in steps:
        p["soak"] = {"minutes": soak_minutes}
    p["args"] = []
    return p


def weight_of(steps, soak_minutes):
    return sum(STEP_S.get(s, 0) for s in steps) + (soak_minutes * 60 + 60 if "soak" in steps else 0)


def wait_for(secret, job_id, claim_deadline, run_s):
    """The finished job (done, failed, cancelled, expired); raises Stop("timeout") when it is not claimed by the deadline or runs past run_s."""
    claimed = None
    while True:
        time.sleep(poll_s)
        try:
            j = call(secret, "GET", "/internal/team/jobs/%s" % job_id)
        except RuntimeError as e:
            say("could not read job %s (%s)" % (job_id, e))
            j = {}
        status = j.get("status")
        if status in ("done", "failed", "cancelled", "expired"):
            return j
        now = time.monotonic()
        if status == "running" and claimed is None:
            claimed = now
            say("job %s taken after %s" % (job_id, took(START)))
        if claimed is None and now > claim_deadline:
            raise Stop("timeout", "no team PC took the checks in time (the PC may be off, paused, or busy with another job)")
        if claimed is not None and now - claimed > run_s:
            raise Stop("timeout", "the team PC did not finish the checks in time")


def main():
    ap = argparse.ArgumentParser(prog="team-check.sh", add_help=True)
    ap.add_argument("rev")
    ap.add_argument("--checks", default="install,quit-loading")
    ap.add_argument("--compare", action="store_true")
    ap.add_argument("--pc", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--soak-minutes", type=int, default=30)
    ap.add_argument("--max-wait", type=float, default=120.0)
    try:
        a = ap.parse_args(sys.argv[2:])
    except SystemExit:
        return 2, None
    steps = [s.strip() for s in a.checks.split(",") if s.strip()]
    bad = [s for s in steps if s not in STEPS]
    if not steps or bad or len(set(steps)) != len(steps) or not (1 <= a.soak_minutes <= 120) or a.max_wait <= 0 or (a.pc and not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", a.pc)):
        say("usage: team-check.sh <rev> [--checks %s] [--compare] [--pc <id>] [--out <dir>] [--soak-minutes 1..120] [--max-wait MINUTES]%s"
            % (",".join(STEPS), " (unknown check: %s)" % ", ".join(bad) if bad else ""))
        return 2, None
    steps = [s for s in STEPS if s in steps]   # the order they run in
    rp = git("rev-parse", "--verify", "-q", a.rev + "^{commit}")
    if rp.returncode != 0:
        say("the checkout %s has no revision %s" % (repo, a.rev))
        return 2, None
    rev = rp.stdout.strip()
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = os.path.abspath(a.out or os.path.join(checks_root, "%s-%s" % (rev[:12], stamp)))
    os.makedirs(out, exist_ok=True)
    state = {"rev": rev, "steps": steps, "out": out, "jobs": [], "folder": None, "pc": None, "lines": [], "sheets": []}
    secret = None
    try:
        try:
            with open(secret_file) as f:
                secret = f.read().strip()
        except OSError as e:
            raise Stop("error", "cannot read the runner's secret (%s)" % e.strerror)
        try:
            pc = choose_pc(secret, a.pc)
        except RuntimeError as e:
            raise Stop("error", "could not ask for the team PCs: %s" % e)
        state["pc"] = pc
        live = None
        if a.compare:
            try:
                with open(manifest_path) as f:
                    live = json.load(f)
            except Exception as e:
                raise Stop("error", "cannot read the live manifest (%s)" % e)
            if not re.fullmatch(r"[0-9a-f]{7,40}", str(live.get("rev", ""))) or not live.get("version"):
                raise Stop("error", "the live manifest names no revision")
            lr = git("rev-parse", "--verify", "-q", str(live["rev"]) + "^{commit}")
            if lr.returncode != 0:
                raise Stop("error", "the checkout has no revision %s (the live build's)" % live["rev"])
            live["rev"] = lr.stdout.strip()
        if not os.path.isdir(root) or os.path.islink(root):
            raise Stop("error", "the team-files folder %s is missing" % root)
        folder = "check-" + secrets.token_hex(12)
        dest = os.path.join(root, folder)
        os.mkdir(dest, 0o755)
        os.chmod(dest, 0o755)
        state["folder"] = dest
        needs_release = any(s not in NEEDS_DEBUG for s in steps)
        needs_debug = any(s in NEEDS_DEBUG for s in steps)
        builds = []   # [(label, version, rev, release entries, debug entries)], live first
        if live is not None:
            d = os.path.join(dest, "live")
            os.mkdir(d, 0o755)
            rel = None
            if needs_release:
                live_dir = os.path.join(os.path.dirname(manifest_path), live["version"])
                for n in RELEASE_FILES + ["DeathMuffin.assets.pck"]:
                    if os.path.isfile(os.path.join(live_dir, n)):
                        link_or_copy(os.path.join(live_dir, n), os.path.join(d, n))
                if any(not os.path.isfile(os.path.join(d, n)) for n in RELEASE_FILES):
                    raise Stop("error", "the live build %s is missing files" % live["version"])
                rel = with_urls(release_entries(d), folder + "/live")
            dbg = with_urls(build_debug(live["rev"], d), folder + "/live/debug") if needs_debug else None
            builds.append(("live", "live build %s" % live["version"], live["rev"], rel, dbg))
        d = os.path.join(dest, "change")
        os.mkdir(d, 0o755)
        rel = None
        if needs_release:
            build_release(rev, d)
            rel = with_urls(release_entries(d), folder + "/change")
        dbg = with_urls(build_debug(rev, d), folder + "/change/debug") if needs_debug else None
        builds.append(("change", "this change %s" % rev[:7], rev, rel, dbg))
        weight = weight_of(steps, a.soak_minutes)
        for label, version, brev, rel, dbg in builds:
            title = ("Checks of the live build %s" % version.split(" ")[-1]) if label == "live" else ("Checks of %s" % rev[:7])
            job = {"kind": "release", "title": title, "weightS": weight, "ttlS": TTL_S, "targetPc": pc["pcId"],
                   "payload": payload_for(version.split(" ")[-1] if label == "live" else rev[:12], brev[:12], steps, rel, dbg, a.soak_minutes)}
            try:
                made = call(secret, "POST", "/internal/team/jobs", job)
            except RuntimeError as e:
                raise Stop("error", "could not queue the checks: %s" % e)
            state["jobs"].append({"label": label, "name": version, "id": made.get("id")})
            say("queued job %s (%s) for %s, %s" % (made.get("id"), version, pc_name(pc), pc.get("gpu") or "?"))
        claim_deadline = time.monotonic() + a.max_wait * 60
        finished = []
        for j in state["jobs"]:
            r = wait_for(secret, j["id"], claim_deadline, weight * 2 + 15 * 60)
            finished.append((j, r))
            claim_deadline = max(claim_deadline, time.monotonic() + 20 * 60)   # the next build's job runs right after on the same PC
        # the summary
        who = "%s (%s)" % (pc_name(pc), pc.get("gpu") or "graphics card unknown")
        head = "**Team PC checks of %s** on %s%s" % (rev[:7], clean(who, 120), (", the live build %s first" % clean(live["version"], 40)) if live else "")
        lines = [head]
        for step in steps:
            for j, r in finished:
                mark, text = step_line(r, step)
                lines.append("%s%s: %s" % (TITLES[step], (" · " + j["name"]) if len(finished) > 1 else "", text))
        if all(r.get("status") != "done" for _, r in finished):
            raise Stop("failed", "the team PC could not run the checks (%s)" % clean(next((r.get("error") for _, r in finished if r.get("error")), "no reason given"), 200))
        sheet_title = ("live %s vs %s" % (live["version"], rev[:7])) if live else rev[:7]
        try:
            sheets, notes = contact_sheets([(j["name"].replace("live build ", "live "), clean(pc.get("gpu") or "", 40, False), r) for j, r in finished if r.get("status") == "done"], sheet_title)
        except ImportError:
            sheets, notes = [], ["no contact sheets: Pillow is not installed"]
        for name, data in sheets:
            p = os.path.join(out, name)
            with open(p, "wb") as f:
                f.write(data)
            state["sheets"].append(p)
        lines += ["(%s)" % n for n in notes]
        state["lines"] = lines
        with open(os.path.join(out, "summary.md"), "w") as f:
            f.write("\n".join(lines) + "\n")
        with open(os.path.join(out, "result.json"), "w") as f:
            json.dump({"rev": rev, "steps": steps, "pc": pc, "jobs": [{"label": j["label"], "name": j["name"], "id": j["id"], "status": r.get("status"),
                       "steps": (r.get("result") or {}).get("steps") if isinstance(r.get("result"), dict) else None} for j, r in finished]}, f, indent=2)
        return 0, dict(state, status="done", why="")
    except Stop as e:
        say(str(e))
        return 1, dict(state, status=e.status, why=str(e))
    finally:
        for j in state["jobs"]:
            if secret and j.get("id"):
                for what in ("cancel", "reported"):
                    try:
                        call(secret, "POST", "/internal/team/jobs/%s/%s" % (j["id"], what))
                    except RuntimeError:
                        pass   # (a finished job cannot be cancelled)
        if state["folder"]:
            shutil.rmtree(state["folder"], ignore_errors=True)
        subprocess.run(["bash", os.path.join(here, "team-files-prune.sh"), root], capture_output=True)   # a killed run's folder, and the old release folders, by age
        try:   # the newest CHECKS_KEEP results folders stay
            if not a_out_given():
                kept = sorted((d for d in os.listdir(checks_root) if os.path.isdir(os.path.join(checks_root, d))), reverse=True)
                for d in kept[CHECKS_KEEP:]:
                    shutil.rmtree(os.path.join(checks_root, d), ignore_errors=True)
        except OSError:
            pass


def a_out_given():
    return "--out" in sys.argv[2:]


def stop(signum, frame):
    raise Stop("error", "stopped")


signal.signal(signal.SIGTERM, stop)
try:
    code, state = main()
except Stop as e:
    code, state = 1, {"status": e.status, "why": str(e)}
if state is not None:
    pc = state.get("pc") or {}
    print("TEAMCHECK: " + json.dumps({"status": state.get("status"), "why": state.get("why", ""), "out": state.get("out"),
                                      "summary": os.path.join(state["out"], "summary.md") if state.get("status") == "done" else None,
                                      "sheets": state.get("sheets", []), "pc": pc.get("pcId"), "gpu": pc.get("gpu"),
                                      "jobs": [{"label": j["label"], "id": j["id"]} for j in state.get("jobs", [])], "lines": state.get("lines", [])}), flush=True)
sys.exit(code)
PY
