#!/usr/bin/env bash
# The team PCs' benchmark of a new client release (ROADMAP Phase 1 "New: the team app", its `bench` job; teamapp/README.md). Called by
# publish-godot-client.sh after a client release is live; best effort: a failure prints a line and the caller carries on.
#
#   team-bench.sh <rev|version>        the live build's version (20261019.120000-abc1234) or its revision (7 hex characters or more)
#
# 1. Reads the live manifest (DM_TEAM_MANIFEST) and checks it is the build asked for; anything else is skipped (this never benchmarks another build).
# 2. Asks the backend which team PCs were seen in the last 14 days (GET /internal/team/pcs?days=14, with the runner's secret): each gets its own job.
#    No PC seen = no job and no files.
# 3. Hard-links the release's files (DeathMuffin.exe, DeathMuffin.pck, the combat core's DLL and, when the build has one, DeathMuffin.assets.pck) from the
#    live build's folder into <team root>/bench-<24 random hex>/ (a copy where a link is not possible): the app downloads only from team-files (one path
#    segment of letters, digits and "-" under it, which the app's address check accepts), and the folder keeps the files after the client folder's own
#    clean-up. Then team-files-prune.sh removes the bench folders older than 4 days (a day past the jobs' 3), separate from the newest-6 rule of the preview
#    builds' 32-hex folders, so a burst of previews never takes the files of a benchmark that is still waiting.
# 4. Queues one `bench` job per PC through POST /internal/team/jobs: targeted at that PC (it is offered to and claimed by that PC only), time to live
#    3 days, title "Benchmark of the new release, about 6 minutes", weight 360, `supersede: true` (the PC's older queued benchmarks are cancelled, so it
#    is only ever offered the newest release's), payload { version, rev, files: [{ name, url, sha256 (from the manifest), bytes, cacheKey? }], setups,
#    args: [] }. The setups are the Full Party fight in the Hollow Graves with a Gravecaller on Low and on Medium, length `full` (the benchmark knows only
#    `quick` and `full`; the same setup the budgets are measured on, CLAUDE.md; team-bench.test.cjs holds every value to the game's own lists in
#    client/next/perf/dm_benchmark.gd); the exe and the art pack carry cacheKeys (the app keeps them across jobs).
#    The app runs each setup as `DeathMuffin.exe ... -- --benchmark --bench-room= --bench-class= --bench-size= --bench-length= --bench-preset= --bench-dir=<dir> --bench-quit`
#    (client/README.md "The benchmark") and sends the runs back in `done` (server/death-muffin/README.md "Team jobs").
# Exit 0: jobs queued, or nothing to do (a line says why). Exit 1: something failed (a line says what). Nothing is left behind on a failure.
# Env (tests override): DM_TEAM_MANIFEST (default /var/www/death-muffin/client/manifest.json), DM_TEAM_ROOT (/var/www/death-muffin/team-files),
#      DM_TEAM_URL (https://muffindevelopment.com/death-muffin/team-files), DM_TEAM_API (http://127.0.0.1:5190, the backend's /internal/team routes),
#      DM_TEAM_SECRET_FILE (/home/ubuntu/death-muffin/discord-agent/secret, the runner's secret), DM_TEAM_DAYS (14), DM_TEAM_KEEP (6, previews),
#      DM_TEAM_BENCH_DAYS (4).
set -uo pipefail
ARG="${1:-}"
[ -n "$ARG" ] || { echo "usage: $0 <rev|version>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null || { echo "team bench: python3 is required" >&2; exit 1; }
exec python3 - "$ARG" "${DM_TEAM_MANIFEST:-/var/www/death-muffin/client/manifest.json}" "${DM_TEAM_ROOT:-/var/www/death-muffin/team-files}" \
  "${DM_TEAM_URL:-https://muffindevelopment.com/death-muffin/team-files}" "${DM_TEAM_API:-http://127.0.0.1:5190}" \
  "${DM_TEAM_SECRET_FILE:-/home/ubuntu/death-muffin/discord-agent/secret}" "${DM_TEAM_DAYS:-14}" "${DM_TEAM_KEEP:-6}" "${DM_TEAM_BENCH_DAYS:-4}" "$HERE/team-files-prune.sh" <<'PY'
import json, os, re, secrets, shutil, subprocess, sys, urllib.error, urllib.request

arg, manifest_path, root, base_url, api, secret_file, days, keep, bench_days, prune_script = sys.argv[1:11]

DLL = "libdmcore.windows.template_release.x86_64.dll"
NEEDED = ["DeathMuffin.exe", "DeathMuffin.pck", DLL]    # a release without these cannot be benchmarked
OPTIONAL = ["DeathMuffin.assets.pck"]                    # the art pack: a revision from before it shipped one pck
TITLE = "Benchmark of the new release, about 6 minutes"
WEIGHT_S = 360
TTL_S = 3 * 86400
SETUPS = [{"preset": preset, "room": "graves", "class": 2, "size": "full_party", "length": "full"} for preset in ("low", "medium")]


OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # the backend is on this machine: never through a proxy from the environment


def say(message):
    print("team bench: " + message, flush=True)


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


def main():
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
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
        say("no team PC was seen in the last %s days: no benchmark jobs" % days)
        return 0
    if not os.path.isdir(root) or os.path.islink(root):
        say("the team-files folder %s is missing" % root)
        return 1
    folder = "bench-" + secrets.token_hex(12)
    dest = os.path.join(root, folder)
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
        shutil.rmtree(dest, ignore_errors=True)
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
    payload = {"version": version, "rev": rev, "files": files, "setups": SETUPS, "args": []}
    made, failed = [], 0
    for pc_id in targets:
        job = {"kind": "bench", "title": TITLE, "weightS": WEIGHT_S, "ttlS": TTL_S, "targetPc": pc_id, "supersede": True, "payload": payload}
        try:
            made.append((pc_id, call(secret, "POST", "/internal/team/jobs", job).get("id")))
        except RuntimeError as e:
            failed += 1
            say("could not queue the benchmark for %s: %s" % (pc_id, e))
    if not made:
        shutil.rmtree(dest, ignore_errors=True)   # nothing will download them
        return 1
    pruned = subprocess.run(["bash", prune_script, root, keep, bench_days])
    if pruned.returncode != 0:
        say("the team-files clean-up failed (exit %d); the next release will try again" % pruned.returncode)
    say("%s (%s): benchmark queued for %d team PC%s (%s); files in %s/%s" % (
        version, rev[:12], len(made), "" if len(made) == 1 else "s", ", ".join("%s job %s" % m for m in made), os.path.basename(root.rstrip("/")), folder))
    return 1 if failed else 0


sys.exit(main())
PY
