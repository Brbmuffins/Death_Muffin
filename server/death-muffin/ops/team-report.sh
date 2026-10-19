#!/usr/bin/env bash
# Posts the release checks of each client release to #build-alerts (timer death-muffin-team-report, every 2 minutes; server/death-muffin/README.md "Team jobs").
#
#   team-report.sh [--dry-run]     --dry-run prints the message instead of posting it and changes nothing (no mark, no state)
#
# Every client release queues one `release` job per team PC (team-release.sh). This script asks the backend (the runner's routes, with the runner's secret) for the release
# jobs that finished and were not reported yet (GET /internal/team/jobs?kind=release&status=finished&unreported=1) and for the ones still queued or running (status=open),
# groups them by release (payload.version), and posts a release ONCE, as one message, when every PC's job has finished or 24 hours have passed since the first was queued:
#   - an embed with a field per PC (its name, owner and graphics card, the cards side by side) and a line per step: ✓ or ✗ and the numbers (the boot in ms, whether quitting
#     while loading worked, the screens' count, the p50/p99 frame times and the 3 worst rites of the stutter run, the bench fps per setup, the soak's growth);
#   - per resolution a contact sheet of the screens (Pillow; rows = PC and UI scale, columns = the shots), at most 4 images, each under 5 MB;
#   - PCs whose job is still queued or running when the 24 hours pass are named as waiting; their results follow in a "late results" message when they finish.
# Only builds that went live are posted (Helix, 2026-10-19: "only builds that are pushed to live should be posted to the build alerts"): a job counts when the release hook
# queued it (its title is "Release checks of <version>"), its version is a folder of the live client (LIVE_DIR), and no job of that version and PC was posted before. Anything
# else (a session's own re-run, a benchmark-only check, a test build that never went live) is marked reported without a post, and an open one never holds a release back.
# Then each reported job is marked (POST /internal/team/jobs/<id>/reported). The numbers come from the job's own result files (the folder named in the job's `files`, which
# must be <team results>/<job id>/ itself and are read without following a link): <step>.json and the screens' PNGs, plus the step list the PC sent with `done`.
# A job whose mark failed after the post went out is only marked again next time (the state file remembers what was posted), never posted twice.
# A backend that has no such route (404) or no table yet (503) is not an error: nothing happens, quietly. The webhook file is read, never printed (nor its address in any message).
# Env (all optional; tests override): RUNTIME (/home/ubuntu/death-muffin), HOOK_FILE ($RUNTIME/private/discord-build-alerts-webhook.url, #build-alerts), STATE
#      ($RUNTIME/ops/state/team-report.json), DM_TEAM_API (http://127.0.0.1:5190), DM_TEAM_SECRET_FILE (the runner's secret), DM_TEAM_RESULTS ($RUNTIME/team-results),
#      WAIT_HOURS (24), SHEET_MAX_BYTES (5 MB, one contact sheet), NOW_MS, LIVE_DIR (/var/www/death-muffin/client: the live builds' folders).
set -uo pipefail
command -v python3 >/dev/null || { echo "team report: python3 is required" >&2; exit 1; }
exec python3 - "$@" <<'PY'
import fcntl, io, json, os, re, stat, sys, time, urllib.error, urllib.request, uuid
from datetime import datetime, timezone

env = os.environ.get
RUNTIME = env("RUNTIME") or "/home/ubuntu/death-muffin"
API = env("DM_TEAM_API") or "http://127.0.0.1:5190"
SECRET_FILE = env("DM_TEAM_SECRET_FILE") or "/home/ubuntu/death-muffin/discord-agent/secret"
RESULTS = os.path.abspath(env("DM_TEAM_RESULTS") or RUNTIME + "/team-results")
LIVE_DIR = env("LIVE_DIR") or "/var/www/death-muffin/client"
HOOK_FILE = env("HOOK_FILE") or RUNTIME + "/private/discord-build-alerts-webhook.url"
STATE = env("STATE") or RUNTIME + "/ops/state/team-report.json"
WAIT_S = float(env("WAIT_HOURS") or 24) * 3600
NOW = float(env("NOW_MS")) / 1000 if env("NOW_MS") else time.time()
DRY = "--dry-run" in sys.argv[1:]

STEPS = ["install", "quit-loading", "screens", "stutter", "bench", "soak"]
TITLES = {"install": "install", "quit-loading": "quit while loading", "screens": "screens", "stutter": "stutter", "bench": "bench", "soak": "soak"}
NEEDS_DEBUG = ("screens", "stutter", "soak")
DISCIPLINES = {1: "Ossuary", 2: "Gravecaller", 3: "Mourner", 4: "Rotweaver", 11: "Reaper"}
PRESETS = ["low", "medium", "high", "ultra"]
JSON_MAX = 1024 * 1024
PNG_MAX = 8 * 1024 * 1024
SHEET_MAX = int(env("SHEET_MAX_BYTES") or 5 * 1024 * 1024)   # each contact sheet: under 8 MB, and four of them stay under the 25 MB a Discord message takes
SHEETS_MAX = 4
SHOT_ORDER = ("bag", "char", "spell", "vault", "map", "hud")
SHOT_RE = re.compile(r"^(\d{3,4})x(\d{3,4})(?:_s(\d+(?:-\d+)?))?_([a-z0-9][a-z0-9_-]*)\.png$")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f​-‏ -‮⁦-⁩﻿]")
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # the backend is on this machine: never through a proxy from the environment


def say(message):
    print("team report: " + message, flush=True)


class ApiError(Exception):
    def __init__(self, status, text):
        super().__init__(text)
        self.status = status


def call(secret, method, path):
    """The backend's answer data; ApiError (status 0 = no answer) otherwise."""
    request = urllib.request.Request(API.rstrip("/") + path, data=b"" if method == "POST" else None, method=method, headers={"X-Team-Secret": secret})
    try:
        with OPENER.open(request, timeout=15) as r:
            answer = json.load(r)
    except urllib.error.HTTPError as e:
        raise ApiError(e.code, "the backend answered %d" % e.code)
    except Exception as e:
        raise ApiError(0, "the backend could not be reached (%s)" % (getattr(e, "reason", None) or type(e).__name__))
    if not isinstance(answer, dict) or not answer.get("success"):
        raise ApiError(200, "the backend did not accept it")
    return answer.get("data") or {}


def job_list(secret, query):
    data = call(secret, "GET", "/internal/team/jobs?" + query)
    rows = data.get("jobs") if isinstance(data, dict) else None
    return [j for j in rows if isinstance(j, dict) and isinstance(j.get("id"), str)] if isinstance(rows, list) else []


# ── small helpers ────────────────────────────────────────────────────────────────────────────────────────────────────

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


def when(text):
    try:
        return datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def version_of(job):
    p = job.get("payload")
    v = p.get("version") if isinstance(p, dict) else None
    return v if isinstance(v, str) and v else "(unknown release)"


def pick(*values):
    for v in values:
        if v is not None:
            return v
    return None


# ── a job's result files ─────────────────────────────────────────────────────────────────────────────────────────────

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


# ── what each step says ──────────────────────────────────────────────────────────────────────────────────────────────

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
    rites = [r for r in rows_of(data, "rites", "rows", "casts", "results") if number(r.get("worst_ms")) is not None]
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


def step_lines(job, steps_wanted):
    """[(mark, text)] for each wanted step: mark 'ok', 'bad' or 'none' (not run)."""
    result = job.get("result") if isinstance(job.get("result"), dict) else {}
    sent = {s.get("step"): s for s in result.get("steps", []) if isinstance(s, dict)}
    payload = job.get("payload") if isinstance(job.get("payload"), dict) else {}
    lines = []
    for step in steps_wanted:
        entry = sent.get(step)
        data = read_json(job, step)
        ok = entry.get("ok") if entry and isinstance(entry.get("ok"), bool) else (data.get("ok") if isinstance(data, dict) and isinstance(data.get("ok"), bool) else None)
        title = TITLES[step]
        if ok is None:
            lines.append(("none", "– %s: %s" % (title, "not reached" if job.get("status") == "failed" else "no result")))
            continue
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
        lines.append(("ok" if ok else "bad", "%s %s: %s" % ("✓" if ok else "✗", title, "; ".join(parts) if parts else "ok")))
    return lines


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


def contact_sheets(entries, version):
    """
    One contact sheet per resolution (at most SHEETS_MAX, the ones with most pictures): a row per PC and UI scale, a column per shot. `entries` is a list of
    (pc name, graphics card, job), the names as plain text. Returns ([(file name, bytes, content type)], notes).
    """
    by_res = {}
    for label, gpu, job in entries:
        for (w, h, scale, shot, name) in screens_of(job):
            by_res.setdefault((w, h), []).append((label, gpu, scale, shot, job, name))
    if not by_res:
        return [], []
    from PIL import Image, ImageDraw   # (an ImportError here is the caller's note: no Pillow, no sheets)
    Image.MAX_IMAGE_PIXELS = 4096 * 4096
    wanted = sorted(sorted(by_res, key=lambda r: -len(by_res[r]))[:SHEETS_MAX], key=lambda r: (r[0] * r[1], r))
    sheets, notes = [], []
    for (w, h) in wanted:
        cells, heads = {}, {}   # (job id, scale, shot) -> thumbnail; (job id, scale) -> what its row says
        for label, gpu, scale, shot, job, name in by_res[(w, h)]:
            raw = read_file(job, name, PNG_MAX)
            if raw is None:
                continue
            try:
                im = Image.open(io.BytesIO(raw)).convert("RGB")
                im = im.resize((480, max(1, int(480 * h / w + 0.5))), Image.LANCZOS)   # a PNG can be 4K: keep only what the sheet needs
            except Exception:
                continue
            cells[(job["id"], scale, shot)] = im
            heads[(job["id"], scale)] = (label, gpu)
        if not cells:
            continue
        rows = sorted(heads, key=lambda k: (heads[k][1].lower(), heads[k][0].lower(), k[0], float(k[1] or 0)))   # the same card side by side, the default scale first
        cols = sorted({k[2] for k in cells}, key=shot_key)
        built = None
        for tw in (360, 270, 200, 140):   # smaller until it fits
            th = max(1, int(tw * h / w + 0.5))
            pad, label_w, head_h = 8, 260, 56
            size = max(11, tw // 24)
            canvas = Image.new("RGB", (label_w + len(cols) * (tw + pad) + pad, head_h + len(rows) * (th + pad) + pad), (24, 24, 28))
            d = ImageDraw.Draw(canvas)
            small, big = font_of(size), font_of(18)
            d.text((pad, 8), "%dx%d  ·  %s" % (w, h, version), font=big, fill=(240, 240, 245))
            for ci, shot in enumerate(cols):
                d.text((label_w + ci * (tw + pad) + pad, head_h - 22), shot.replace("_", " ")[:28], font=small, fill=(190, 190, 200))
            for ri, key in enumerate(rows):
                y = head_h + ri * (th + pad)
                label, gpu = heads[key]
                for li, (text, fill) in enumerate(((label[:30], (240, 240, 245)), (gpu[:32], (160, 160, 170)), (("UI scale " + key[1]) if key[1] else "default UI scale", (160, 160, 170)))):
                    d.text((pad, y + 4 + li * (size + 6)), text, font=small, fill=fill)
                for ci, shot in enumerate(cols):
                    x = label_w + ci * (tw + pad) + pad
                    im = cells.get((key[0], key[1], shot))
                    if im is None:
                        d.rectangle((x, y, x + tw - 1, y + th - 1), fill=(46, 46, 52))
                        d.text((x + tw // 2 - 4, y + th // 2 - size // 2), "–", font=small, fill=(110, 110, 120))
                    else:
                        canvas.paste(im.resize((tw, th), Image.LANCZOS), (x, y))
            for ext, kind, ctype in (("png", "PNG", "image/png"), ("jpg", "JPEG", "image/jpeg")):
                buf = io.BytesIO()
                canvas.save(buf, kind, **({"quality": 86} if kind == "JPEG" else {}))
                if buf.tell() <= SHEET_MAX:
                    built = ("screens-%dx%d.%s" % (w, h, ext), buf.getvalue(), ctype)
                    break
            if built:
                break
        if built:
            sheets.append(built)
        else:
            notes.append("the %dx%d sheet was too large to attach" % (w, h))
    return sheets, notes


# ── the message ──────────────────────────────────────────────────────────────────────────────────────────────────────

def compose(version, group, waiting, pcs, late):
    """The webhook payload (one embed) and the files to attach for one release. `group` = finished jobs, `waiting` = jobs still open (None when they could not be listed)."""
    payload0 = group[0].get("payload") if isinstance(group[0].get("payload"), dict) else {}
    rev = str(payload0.get("rev", ""))[:12]
    queued_steps = payload0.get("steps") if isinstance(payload0.get("steps"), list) else STEPS
    steps = [s for s in STEPS if s in queued_steps]

    def who(job, markdown=True):
        pc_id = job.get("claimedPc") or job.get("targetPc") or ""
        p = pcs.get(pc_id, {})
        name = clean(p.get("name") or pc_id or "a team PC", 40, markdown) + (" (%s)" % clean(p.get("username"), 30, markdown) if p.get("username") else "")
        return name, clean(p.get("gpu") or "unknown graphics card", 60, markdown)

    entries, fields, good, bad, off, bad_pcs = [], [], 0, 0, 0, 0
    for job in group:
        label, gpu = who(job)
        lines = step_lines(job, steps)
        if job.get("status") == "failed":
            lines.insert(0, ("bad", "✗ the job failed: %s" % clean(job.get("error") or "no reason given", 200)))
        good += sum(1 for m, _ in lines if m == "ok")
        bad += sum(1 for m, _ in lines if m == "bad")
        off += sum(1 for m, _ in lines if m == "none")
        bad_pcs += 1 if any(m == "bad" for m, _ in lines) else 0
        text = "\n".join(t[:260] for _, t in lines)
        fields.append({"name": ("%s · %s" % (label, gpu))[:256], "value": text[:1024] or "no result", "inline": False, "_gpu": gpu, "_label": label})
        plain, plain_gpu = who(job, False)
        entries.append((plain, plain_gpu, job))
    fields.sort(key=lambda f: (f["_gpu"].lower(), f["_label"].lower()))   # the same graphics card side by side
    sheets, notes = [], []
    try:
        sheets, notes = contact_sheets(entries, version)
    except ImportError:
        notes.append("Pillow is not installed: no contact sheets")
    except Exception as e:
        notes.append("the contact sheets failed (%s)" % type(e).__name__)
    n = len(group)
    desc = []
    if bad:
        desc.append("**%d of %d checks failed** on %d of %d team PC%s." % (bad, good + bad, bad_pcs, n, "" if n == 1 else "s"))
    elif good:
        desc.append("**All %d checks passed** on %d team PC%s." % (good, n, "" if n == 1 else "s"))
    else:
        desc.append("**No check produced a result** on %d team PC%s." % (n, "" if n == 1 else "s"))
    if off:
        desc.append("%d step%s did not run or sent no result." % (off, "" if off == 1 else "s"))
    skipped = [s for s in NEEDS_DEBUG if s not in queued_steps]
    if skipped:
        desc.append("No debug build was made for this release, so %s were not queued." % ", ".join(TITLES[s] for s in skipped))
    if waiting:
        desc.append("⏳ Still waiting after %d hours: %s. Their results follow when they finish." % (round(WAIT_S / 3600), ", ".join("%s (%s)" % (who(j)[0], j.get("status", "waiting")) for j in waiting)))
    if waiting is None:
        desc.append("(The jobs still open could not be listed, so this may not be every PC.)")
    if sheets:
        desc.append("Contact sheets of the screens (%s) are attached." % ", ".join(f[0].split("-", 1)[1].rsplit(".", 1)[0] for f in sheets))
    desc.extend(t[0].upper() + t[1:] + "." for t in notes)
    color = 0xE74C3C if bad else 0xF1C40F if (off or waiting) else 0x2ECC71
    embed = {"title": ("Release checks of %s%s" % (clean(version, 60), " (late results)" if late else ""))[:256], "description": "\n".join(desc)[:3000], "color": color,
             "fields": [{k: v for k, v in f.items() if not k.startswith("_")} for f in fields][:25]}
    if rev:
        embed["footer"] = {"text": "rev " + rev}
    while len(json.dumps(embed["fields"], ensure_ascii=False)) + len(embed["description"]) + len(embed["title"]) > 5600 and len(embed["fields"]) > 1:
        embed["fields"].pop()   # a message holds 6000 characters: the PCs that fit (the last are the ones on the cards sorted last)
        embed["description"] += "\n(a PC was left out to fit the message)"
    body = {"username": "Death Muffin Release Checks", "allowed_mentions": {"parse": []}, "embeds": [embed]}
    if sheets:
        body["attachments"] = [{"id": i, "filename": f[0]} for i, f in enumerate(sheets)]
    return body, sheets, (good, bad, off)


def post(url, body, sheets):
    """Post one message; raises RuntimeError with words that never include the webhook address."""
    if sheets:
        boundary = uuid.uuid4().hex
        parts = [("--%s\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n" % boundary).encode() + json.dumps(body).encode() + b"\r\n"]
        for i, (name, data, ctype) in enumerate(sheets):
            parts.append(("--%s\r\nContent-Disposition: form-data; name=\"files[%d]\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n" % (boundary, i, name, ctype)).encode() + data + b"\r\n")
        data, ctype = b"".join(parts) + ("--%s--\r\n" % boundary).encode(), "multipart/form-data; boundary=" + boundary
    else:
        data, ctype = json.dumps(body).encode(), "application/json"
    try:
        request = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": ctype, "User-Agent": "death-muffin-team-report"})   # (Discord refuses urllib's own agent)
        with OPENER.open(request, timeout=60) as r:
            if r.status >= 300:
                raise RuntimeError("HTTP %d" % r.status)
    except urllib.error.HTTPError as e:
        raise RuntimeError("HTTP %d" % e.code)
    except RuntimeError:
        raise
    except ValueError:
        raise RuntimeError("the webhook address is not a valid web address")
    except Exception as e:
        raise RuntimeError("no answer (%s)" % type(e).__name__)


# ── the state: what was posted ───────────────────────────────────────────────────────────────────────────────────────

def load_state():
    try:
        with open(STATE) as f:
            s = json.load(f)
        return {"jobs": dict(s.get("jobs", {})), "versions": dict(s.get("versions", {})), "pcs": dict(s.get("pcs", {}))}
    except (OSError, ValueError, AttributeError, TypeError):
        return {"jobs": {}, "versions": {}, "pcs": {}}


def save_state(state):
    keep = lambda d, n: dict(sorted(d.items(), key=lambda kv: kv[1])[-n:])
    out = {"jobs": keep(state["jobs"], 300), "versions": keep(state["versions"], 60), "pcs": keep(state["pcs"], 300)}
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f)
    os.replace(tmp, STATE)


def pc_of(job):
    return str(job.get("claimedPc") or job.get("targetPc") or "")


def hook_job(job):
    """Queued by the release hook (team-release.sh), not by hand: only those are a release's checks."""
    return str(job.get("title") or "").startswith("Release checks of ")


def went_live(version):
    """The version is a build of the live client (its folder in LIVE_DIR), not a test build."""
    if not version or "/" in version or version.startswith("."):
        return False
    path = os.path.join(LIVE_DIR, version)
    return os.path.isdir(path) and not os.path.islink(path)


def main():
    if not DRY:
        try:
            os.makedirs(os.path.dirname(STATE), exist_ok=True)
            lock = open(STATE + ".lock", "w")   # held until this run ends
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0   # another run is posting
        except OSError as e:
            say("cannot use the state folder %s (%s)" % (os.path.dirname(STATE), e.strerror))
            return 1
    try:
        with open(SECRET_FILE) as f:
            secret = f.read().strip()
    except OSError as e:
        say("cannot read the runner's secret %s (%s)" % (SECRET_FILE, e.strerror))
        return 1
    try:
        finished = job_list(secret, "kind=release&status=finished&unreported=1&limit=100")
    except ApiError as e:
        if e.status in (404, 503):   # the backend has no such route (yet) or no table (yet)
            return 0
        say("could not list the finished release checks: %s" % e)
        return 0 if e.status == 0 else 1   # a backend that is down is the health watch's to report; the next run asks again
    if not finished:
        return 0
    state = load_state()
    failures, failures_note = 0, []

    def mark(ids):
        marked = 0
        for job_id in ids:
            try:
                call(secret, "POST", "/internal/team/jobs/%s/reported" % job_id)
                marked += 1
            except ApiError as e:
                failures_note.append("could not mark job %s reported: %s" % (job_id, e))
        return marked
    posted_before = [j["id"] for j in finished if j["id"] in state["jobs"]]   # posted, but the mark failed last time: mark again, never post twice
    if posted_before and not DRY:
        mark(posted_before)
    finished = [j for j in finished if j["id"] not in state["jobs"]]
    # only a live build's own checks are posted, one job per release and PC (the oldest): the rest is marked without a post
    kept, quiet, seen = [], [], set(state["pcs"])
    for j in sorted(finished, key=lambda j: when(j.get("createdAt")) or NOW):
        key = "%s|%s" % (version_of(j), pc_of(j))
        if hook_job(j) and went_live(version_of(j)) and key not in seen:
            seen.add(key)
            kept.append(j)
        else:
            quiet.append(j)
    if quiet and not DRY:
        n = mark([j["id"] for j in quiet])
        say("not posted (not a live release's own check, or one of its PC was posted already): %d job%s marked reported" % (n, "" if n == 1 else "s"))
    finished = kept
    if not finished:
        for n in failures_note:
            say(n)
        return 1 if failures_note else 0
    waiting_all = None
    try:
        waiting_all = job_list(secret, "kind=release&status=open&limit=100")
    except ApiError as e:
        say("could not list the release checks still open (%s): reports wait for the %d hours" % (e, round(WAIT_S / 3600)))
    pcs = {}
    try:
        for pc in call(secret, "GET", "/internal/team/pcs?days=60").get("pcs") or []:
            if isinstance(pc, dict) and isinstance(pc.get("pcId"), str):
                pcs.setdefault(pc["pcId"], pc)
    except ApiError:
        pass   # the lines name the PC by its id then
    groups = {}
    for job in finished:
        groups.setdefault(version_of(job), []).append(job)
    order = sorted(groups, key=lambda v: min(when(j.get("createdAt")) or NOW for j in groups[v]))
    hook = None
    for version in order:
        group = groups[version]
        waiting = None if waiting_all is None else [j for j in waiting_all if version_of(j) == version and hook_job(j)]
        first = min(when(j.get("createdAt")) or NOW for j in group + (waiting or []))
        if not ((waiting is not None and not waiting) or NOW - first >= WAIT_S):
            continue   # another PC is still working on this release (and 24 hours have not passed)
        body, sheets, (good, bad, off) = compose(version, group, waiting, pcs, version in state["versions"])
        if DRY:
            e = body["embeds"][0]
            print("== %s\n%s" % (e["title"], e["description"]))
            for f in e["fields"]:
                print("-- %s\n%s" % (f["name"], f["value"]))
            for n, data, _ in sheets:
                print("[attached %s, %d bytes]" % (n, len(data)))
            continue
        if hook is None:
            try:
                with open(HOOK_FILE) as f:
                    hook = "".join(f.read().split())
            except OSError:
                say("no webhook file: nothing was posted")
                return 1
        try:
            post(hook, body, sheets)
        except RuntimeError as e:
            say("the #build-alerts post for %s failed (%s); trying again next run" % (version, e))
            failures += 1
            continue
        now_iso = datetime.fromtimestamp(NOW, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        for j in group:
            state["jobs"][j["id"]] = now_iso
            state["pcs"]["%s|%s" % (version, pc_of(j))] = now_iso
        state["versions"][version] = now_iso
        save_state(state)
        marked = mark([j["id"] for j in group])
        say("posted the release checks of %s: %d PC%s, %d ok, %d failed, %d not run, %d contact sheet%s; %d job%s marked reported" % (
            version, len(group), "" if len(group) == 1 else "s", good, bad, off, len(sheets), "" if len(sheets) == 1 else "s", marked, "" if marked == 1 else "s"))
    for n in failures_note:
        say(n)
    return 1 if failures or failures_note else 0


sys.exit(main())
PY
