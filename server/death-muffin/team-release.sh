#!/usr/bin/env bash
# The team PCs' release checks of a new client release (ROADMAP Phase 1 "New: the team app", its `release` job; teamapp/README.md). Called by
# publish-godot-client.sh after a client release is live; best effort: a failure prints a line and the caller carries on.
#
#   team-release.sh <rev|version>        the live build's version (20261019.120000-abc1234) or its revision (7 hex characters or more)
#
# 1. Reads the live manifest (DM_TEAM_MANIFEST) and checks it is the build asked for; anything else is skipped (this never checks another build).
# 2. Asks the backend which team PCs were seen in the last 14 days (GET /internal/team/pcs?days=14, with the runner's secret): each gets its own job.
#    No PC seen = no job, no files and no debug build.
# 3. Hard-links the release's files (DeathMuffin.exe, DeathMuffin.pck, the combat core's DLL and, when the build has one, DeathMuffin.assets.pck) from the
#    live build's folder into <team root>/release-<24 random hex>/ (a copy where a link is not possible): the app downloads only from team-files, and the folder
#    keeps the files after the client folder's own clean-up. team-files-prune.sh removes release folders older than 4 days (a day past the jobs' 3), separate
#    from the newest-6 rule of the preview builds' 32-hex folders, so a burst of previews never takes the files of a check that is still waiting.
# 4. Builds the DEBUG export of the same revision (the screens, stutter and soak steps need the QA tools, which start only in a debug build): a scratch worktree of
#    the revision, then its own `discord-agent/preview-godot.sh <6 hex> --team` there under `nice -n 10` (a limit of 25 minutes; the whole process group is stopped
#    at it), then the worktree is removed. preview-godot.sh makes <team root>/<32 hex>/ and ends with a `TEAMFILES: [...]` line; that folder is moved to
#    <release folder>/debug/ (so it ages out with the release and never counts among the preview builds) and the addresses are rewritten. If the build fails or
#    this revision's preview-godot.sh has no --team, the jobs go without the steps that need it (and a lighter weight).
# 5. Queues one `release` job per PC through POST /internal/team/jobs: targeted at that PC (it is offered to and claimed by that PC only), time to live 3 days,
#    title "Release checks of <version>" (the app adds "about N minutes" from the weight), weight 2400, `supersede: true` (the PC's older queued release checks are cancelled, so it is only ever
#    offered the newest release's), payload { version, rev, godotVersion, builds: [{ label: "release", files: [{ name, url, sha256 (from the manifest), bytes, cacheKey? }] },
#    { label: "debug", files: [...] }], steps: [install, quit-loading, screens, stutter, bench, soak], setups, screens: { plan: { shots: [the standard UI shots] },
#    resolutions: [1920x1080, 2560x1440, 3840x2160, 3440x1440], preset: "high" }, soak: { minutes: 30 }, args: [] } (the shape teamapp/windows/JobPlan.cs ParseRelease reads).
#    The bench setups are the Full Party fight in the Hollow Graves with a Gravecaller on Low and on Medium, length `full` (the benchmark knows only `quick` and
#    `full`; the same setup the budgets are measured on, CLAUDE.md; team-release.test.cjs holds every value to the game's own lists in client/next/perf/dm_benchmark.gd);
#    the exe and the art pack carry cacheKeys (the app keeps them across jobs). Without a debug build: no `debug` entry in builds, no `screens` and `soak`
#    settings, steps install, quit-loading and bench, weight 600.
#    Before it queues anything it checks the live manifest still names this build (another publish may have gone live during the debug build).
# The results come back through the backend and are posted to #build-alerts by ops/team-report.sh (README.md "Team jobs").
# Exit 0: jobs queued, or nothing to do (a line says why). Exit 1: something failed (a line says what). Nothing is left behind on a failure, and every phase
# prints how long it took (the publish runs this: the debug build is most of it).
# Env (tests override): DM_TEAM_MANIFEST (default /var/www/death-muffin/client/manifest.json), DM_TEAM_ROOT (/var/www/death-muffin/team-files),
#      DM_TEAM_URL (https://muffindevelopment.com/death-muffin/team-files), DM_TEAM_API (http://127.0.0.1:5190, the backend's /internal/team routes),
#      DM_TEAM_SECRET_FILE (/home/ubuntu/death-muffin/discord-agent/secret, the runner's secret), DM_TEAM_DAYS (14), DM_TEAM_KEEP (6, previews),
#      DM_TEAM_RELEASE_DAYS (4), DM_TEAM_REPO (the shared checkout, /home/ubuntu/vps-handoffs/DeathMuffin/game), DM_TEAM_WORK (where the scratch worktree
#      goes, /home/ubuntu/death-muffin/deploy), DM_TEAM_PREVIEW (a preview-godot.sh other than the revision's own), DM_TEAM_BUILD_TIMEOUT (1500 seconds),
#      DM_TEAM_NICE (10).
set -uo pipefail
ARG="${1:-}"
[ -n "$ARG" ] || { echo "usage: $0 <rev|version>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null || { echo "team release: python3 is required" >&2; exit 1; }
exec python3 - "$ARG" "$HERE/team-files-prune.sh" <<'PY'
import json, os, re, secrets, shutil, signal, subprocess, sys, tempfile, time, urllib.error, urllib.request

arg, prune_script = sys.argv[1:3]
env = os.environ.get
manifest_path = env("DM_TEAM_MANIFEST") or "/var/www/death-muffin/client/manifest.json"
root = env("DM_TEAM_ROOT") or "/var/www/death-muffin/team-files"
base_url = env("DM_TEAM_URL") or "https://muffindevelopment.com/death-muffin/team-files"
api = env("DM_TEAM_API") or "http://127.0.0.1:5190"
secret_file = env("DM_TEAM_SECRET_FILE") or "/home/ubuntu/death-muffin/discord-agent/secret"
days = env("DM_TEAM_DAYS") or "14"
keep = env("DM_TEAM_KEEP") or "6"
release_days = env("DM_TEAM_RELEASE_DAYS") or "4"
repo = env("DM_TEAM_REPO") or "/home/ubuntu/vps-handoffs/DeathMuffin/game"
work = env("DM_TEAM_WORK") or "/home/ubuntu/death-muffin/deploy"
preview_override = env("DM_TEAM_PREVIEW") or ""
build_timeout = int(env("DM_TEAM_BUILD_TIMEOUT") or 1500)
nice_level = env("DM_TEAM_NICE") or "10"

DLL = "libdmcore.windows.template_release.x86_64.dll"
NEEDED = ["DeathMuffin.exe", "DeathMuffin.pck", DLL]    # a release without these cannot be checked
OPTIONAL = ["DeathMuffin.assets.pck"]                    # the art pack: a revision from before it shipped one pck
DEBUG_NEEDED = ["DeathMuffinDebug.exe", "DeathMuffinDebug.pck", DLL]
STEPS = ["install", "quit-loading", "screens", "stutter", "bench", "soak"]
NEEDS_DEBUG = ("screens", "stutter", "soak")             # the QA scenarios start only in a debug build
SOAK_MINUTES = 30
GODOT_VERSION = "4.7.2.stable"   # CLAUDE.md: Godot stays 4.7.2 until a deliberate, benchmarked upgrade (the screenshots job names it the same way)
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
TITLE = "Release checks of %s"   # no duration in the title: the app adds ", about N minutes" from the weight
WEIGHT_S = 2400                  # about 40 minutes: install, quit while loading, the screens, the stutter run, the two benchmarks and a 30-minute soak
WEIGHT_NO_DEBUG_S = 600          # without the debug build: install, quit while loading and the two benchmarks
TTL_S = 3 * 86400
SETUPS = [{"preset": preset, "room": "graves", "class": 2, "size": "full_party", "length": "full"} for preset in ("low", "medium")]
START = time.monotonic()
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # the backend is on this machine: never through a proxy from the environment


def say(message):
    print("team release: " + message, flush=True)


def took(since):
    return "%d s" % round(time.monotonic() - since)


def call(secret, method, path, body=None):
    """The backend's answer data; raises RuntimeError with a readable reason."""
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


def read_manifest():
    with open(manifest_path) as f:
        return json.load(f)


def kill_group(proc):
    """Stops a build and everything it started (godot, the sandbox): the build runs in its own process group."""
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


def git(*args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def build_debug(rev, dest):
    """
    The debug export of `rev` (preview-godot.sh --team from a scratch worktree of it), its folder moved to <dest>/debug. Returns (entries, None) with the payload's file
    entries, or (None, why): never raises, and leaves no worktree and no stray preview folder behind.
    """
    began = time.monotonic()
    if git("cat-file", "-e", rev + "^{commit}").returncode != 0:
        return None, "the checkout %s does not have revision %s" % (repo, rev[:12])
    wt = os.path.join(work, "team-release-wt-%s-%s" % (rev[:12], secrets.token_hex(3)))
    preview_dir = None
    proc = None
    log = tempfile.TemporaryFile()
    try:
        os.makedirs(work, exist_ok=True)
        added = git("worktree", "add", "-q", "--detach", wt, rev)
        if added.returncode != 0:
            return None, "could not make a worktree of %s (%s)" % (rev[:12], (added.stderr.strip().splitlines() or ["git failed"])[-1])
        script = preview_override or os.path.join(wt, "server/death-muffin/discord-agent/preview-godot.sh")
        try:
            with open(script) as f:
                has_team = "--team" in f.read()
        except OSError:
            has_team = False
        if not has_team:   # an older revision's script would write a preview zip instead (and know nothing of --team)
            return None, "this revision's preview-godot.sh has no --team"
        say("building the debug export of %s (preview-godot.sh --team, nice %s, at most %d s)" % (rev[:12], nice_level, build_timeout))
        child_env = dict(os.environ, DM_TEAM_ROOT=root, DM_TEAM_URL=base_url, CLIENT_MANIFEST=manifest_path)
        proc = subprocess.Popen(["nice", "-n", nice_level, "bash", script, secrets.token_hex(3), "--team"], cwd=wt, env=child_env, stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            proc.wait(build_timeout)
        except subprocess.TimeoutExpired:
            kill_group(proc)
            return None, "the build took longer than %d s and was stopped" % build_timeout
        log.seek(0)
        output = log.read().decode("utf-8", "replace")
        lines = [l for l in output.splitlines() if l.strip()]
        line = next((l for l in reversed(lines) if l.startswith("TEAMFILES: ")), None)
        try:
            built = json.loads(line[len("TEAMFILES: "):]) if line else None
        except ValueError:
            built = None
        if line:
            m = re.search(r"/([0-9a-f]{32})/[^/]+$", built[0].get("url", "") if isinstance(built, list) and built and isinstance(built[0], dict) else "")
            preview_dir = os.path.join(root, m.group(1)) if m else None   # whatever it made is ours to remove again on a failure
        if proc.returncode != 0 or not isinstance(built, list) or not built or not preview_dir:
            tail = " ".join(l.strip() for l in lines[-2:])[:200]
            return None, "the build failed (exit %s)%s" % (proc.returncode, ": " + tail if tail else "")
        if os.path.islink(preview_dir) or not os.path.isdir(preview_dir):
            return None, "the build's folder %s is missing" % os.path.basename(preview_dir)
        entries = []
        for e in built:
            name = e.get("name") if isinstance(e, dict) else None
            path = os.path.join(preview_dir, name) if isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9._-]{1,80}", name) else None
            if not path or os.path.islink(path) or not os.path.isfile(path) or os.path.getsize(path) != e.get("bytes") or not re.fullmatch(r"[0-9a-f]{64}", str(e.get("sha256", ""))):
                return None, "the build's file list does not match its folder (%s)" % (name,)
            entry = {"name": name, "url": "%s/%s/debug/%s" % (base_url.rstrip("/"), os.path.basename(dest), name), "sha256": e["sha256"], "bytes": e["bytes"]}
            if e.get("cacheKey"):
                entry["cacheKey"] = e["cacheKey"]
            entries.append(entry)
        missing = [n for n in DEBUG_NEEDED if n not in [e["name"] for e in entries]]
        if missing:
            return None, "the build has no %s" % ", ".join(missing)
        os.rename(preview_dir, os.path.join(dest, "debug"))   # the same file system: it ages out with the release and is not one of the preview builds
        preview_dir = None
        say("the debug export is ready (%s)" % took(began))
        return entries, None
    except Exception as e:   # best effort: the checks that need no debug build still go
        return None, "the build could not be made (%s)" % (getattr(e, "strerror", None) or e)
    finally:
        if proc is not None and proc.poll() is None:
            kill_group(proc)
        if preview_dir:
            shutil.rmtree(preview_dir, ignore_errors=True)
        git("worktree", "remove", "--force", wt)
        shutil.rmtree(wt, ignore_errors=True)
        git("worktree", "prune")
        log.close()


def main():
    try:
        manifest = read_manifest()
    except Exception as e:
        say("cannot read the live manifest %s (%s)" % (manifest_path, e))
        return 1
    version = str(manifest.get("version", ""))
    rev = str(manifest.get("rev", ""))
    if not (arg == version or (len(arg) >= 7 and rev and (rev.startswith(arg) or arg.startswith(rev)))):
        say("the live build is %s (%s), not %s: skipped" % (version, rev[:12], arg))
        return 0
    by_path = {f.get("path"): f for f in manifest.get("files", []) if isinstance(f, dict)}
    missing = [n for n in NEEDED if n not in by_path]
    if missing:
        say("the live build %s has no %s: skipped" % (version, ", ".join(missing)))
        return 0
    names = NEEDED + [n for n in OPTIONAL if n in by_path]
    build_dir = os.path.join(os.path.dirname(manifest_path), version)
    for n in names:
        src = os.path.join(build_dir, n)
        m = by_path[n]
        if not re.fullmatch(r"[0-9a-f]{64}", str(m.get("sha256", ""))):
            say("the manifest has no sha256 for %s" % n)
            return 1
        if os.path.islink(src) or not os.path.isfile(src) or os.path.getsize(src) != m.get("size"):
            say("%s is not the file the manifest describes (missing or another size)" % src)
            return 1
    try:
        with open(secret_file) as f:
            secret = f.read().strip()
    except OSError as e:
        say("cannot read the runner's secret %s (%s)" % (secret_file, e.strerror))
        return 1
    try:
        pcs = call(secret, "GET", "/internal/team/pcs?days=%s" % days).get("pcs") or []
    except RuntimeError as e:
        say("could not list the team PCs: %s" % e)
        return 1
    targets = []
    for pc in pcs:
        pc_id = pc.get("pcId") if isinstance(pc, dict) else None
        if isinstance(pc_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{8,64}", pc_id) and pc_id not in targets:   # one job per PC, however many accounts signed in on it
            targets.append(pc_id)
    if not targets:
        say("no team PC was seen in the last %s days: no release checks" % days)
        return 0
    if not os.path.isdir(root) or os.path.islink(root):
        say("the team-files folder %s is missing" % root)
        return 1
    folder = "release-" + secrets.token_hex(12)
    dest = os.path.join(root, folder)
    made, failed = [], 0
    try:
        try:
            os.mkdir(dest, 0o755)
            os.chmod(dest, 0o755)
            for n in names:
                src, dst = os.path.join(build_dir, n), os.path.join(dest, n)
                try:
                    os.link(src, dst)
                except OSError:
                    shutil.copyfile(src, dst)
                    os.chmod(dst, 0o644)
        except OSError as e:
            say("could not put the release files in %s (%s)" % (dest, e.strerror or e))
            return 1
        files = []
        for n in names:
            sha = by_path[n]["sha256"]
            entry = {"name": n, "url": "%s/%s/%s" % (base_url.rstrip("/"), folder, n), "sha256": sha, "bytes": by_path[n]["size"]}
            if n == "DeathMuffin.exe":
                entry["cacheKey"] = "godot-release-" + sha[:16]   # the release template: the same until Godot or the export settings change
            if n == "DeathMuffin.assets.pck":
                entry["cacheKey"] = "assets-" + sha[:16]          # about 500 MB: downloaded once per pack
            files.append(entry)
        debug, why = build_debug(rev, dest)
        if debug is None:
            say("no debug build (%s): the release checks go without %s" % (why, ", ".join(NEEDS_DEBUG)))
        try:   # another publish may have gone live while the debug build ran: it queues its own checks
            now_live = read_manifest()
        except Exception:
            now_live = {}
        if str(now_live.get("version", "")) != version:
            say("the live build is now %s, not %s: no release checks for it" % (now_live.get("version", "(unreadable)"), version))
            return 0
        steps = [s for s in STEPS if debug is not None or s not in NEEDS_DEBUG]
        weight = WEIGHT_S if debug is not None else WEIGHT_NO_DEBUG_S
        builds = [{"label": "release", "files": files}] + ([{"label": "debug", "files": debug}] if debug is not None else [])
        payload = {"version": version, "rev": rev, "godotVersion": GODOT_VERSION, "builds": builds, "steps": steps, "setups": SETUPS}
        if "screens" in steps:
            payload["screens"] = {"plan": SCREEN_PLAN, "resolutions": RESOLUTIONS, "preset": SCREENS_PRESET}
        if "soak" in steps:
            payload["soak"] = {"minutes": SOAK_MINUTES}
        payload["args"] = []
        for pc_id in targets:
            job = {"kind": "release", "title": TITLE % version, "weightS": weight, "ttlS": TTL_S, "targetPc": pc_id, "supersede": True, "payload": payload}
            try:
                made.append((pc_id, call(secret, "POST", "/internal/team/jobs", job).get("id")))
            except RuntimeError as e:
                failed += 1
                say("could not queue the release checks for %s: %s" % (pc_id, e))
        if not made:
            return 1
        pruned = subprocess.run(["bash", prune_script, root, keep, release_days])
        if pruned.returncode != 0:
            say("the team-files clean-up failed (exit %d); the next release will try again" % pruned.returncode)
        say("%s (%s): release checks queued for %d team PC%s (%s; %s); files in %s/%s; done in %s" % (
            version, rev[:12], len(made), "" if len(made) == 1 else "s", ", ".join("%s job %s" % m for m in made),
            "with the debug build" if debug is not None else "without the debug build", os.path.basename(root.rstrip("/")), folder, took(START)))
        return 1 if failed else 0
    finally:
        if not made:   # nothing will download them
            shutil.rmtree(dest, ignore_errors=True)


def stop(signum, frame):
    raise SystemExit(143)   # the publish's timeout: the finally clauses above remove the folder and the worktree and stop the build


signal.signal(signal.SIGTERM, stop)
code = main()
if code != 0:
    say("stopped after %s" % took(START))
sys.exit(code)
PY
