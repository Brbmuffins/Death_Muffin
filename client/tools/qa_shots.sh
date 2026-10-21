#!/usr/bin/env bash
# The pictures of a proposal, rendered from the CLIENT (the game) on this VPS: a shot plan in, raw PNGs out (client/main/SCREENSHOTS.md).
#   client/tools/qa_shots.sh <plan.json> <out_dir> [class]
# The plan is the format of client/main/qa_ui_shots.gd (windows, tooltips, `equip`, `discipline`, `view` hero|game, `turn`, `anim`, `area`, `wait_ms`; at most 6 shots, a plan with more is refused). `class` is the discipline's
# class number (1 Ossuary, 2 Gravecaller, 3 Mourner, 4 Rotweaver, 11 Reaper); without it the plan's `discipline` is used, and 2 when the plan has none. The game starts as the dev-offline hero `tester`
# on the local mock backend, in a scratch user folder of its own (nothing is written to the real one, nothing reaches a server), with
# `-- --dev-offline --class=N --qa --shot-plan=<plan> --shots=<out_dir>`.
# Forward+ (the renderer the game plays on) on the software Vulkan driver (lavapipe: the VPS has no GPU). If Vulkan cannot start, the run is repeated on the OpenGL 3 fallback and a line says so:
# the pictures then have Compatibility's look, not the game's. One renderer at a time across every agent (the shared qa-browser.lock: it waits up to 15 minutes for it), at `nice -n 10`, and at most
# 10 minutes once it has the lock. Needs `bash tools/check/prep.sh` once per checkout (the combat core, the import and the crowd's baked models, without which a plan's enemies and thralls are not drawn).
# Exit code: godot's (0 the pictures are there, 1 a shot failed, 2 the plan or the launch is wrong); 124 timed out, 75 the lock was not free in time.
# Env: GODOT (default /home/ubuntu/tools/godot/godot), DM_BROWSER_LOCK, DM_QA_LIMIT (seconds, default 600), DM_QA_ICD (the lavapipe ICD file), DM_QA_FALLBACK=force|never (the other renderer; tests),
# DM_QA_LOG=<file> (keeps godot's whole log of the run there: the script itself shows only the game's QA-SHOTS lines and its errors), DM_QA_LOCKED=1 (the caller holds the renderer lock already: it is not taken again).
set -uo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
PROJECT=$(cd "$(dirname "$SELF")/.." && pwd)
GODOT=${GODOT:-/home/ubuntu/tools/godot/godot}
LOCK=${DM_BROWSER_LOCK:-/home/ubuntu/death-muffin/qa-browser.lock}
LIMIT=${DM_QA_LIMIT:-600}
ICD=${DM_QA_ICD:-/usr/share/vulkan/icd.d/lvp_icd.x86_64.json}

# ---- the part that holds the lock: started by the outer part below with --render
if [ "${1:-}" = "--render" ]; then
  PLAN=$2 OUT=$3 CLASS=$4
  SCR=$(mktemp -d /tmp/dm-qa-shots.XXXXXX) || exit 2
  trap 'rm -rf "$SCR"' EXIT
  trap 'exit 143' TERM INT HUP   # the time limit's TERM ends the run through the trap above, so the scratch folder goes too
  mkdir -p "$SCR/data" "$SCR/config" "$OUT" || exit 2
  # Godot's user:// (the dev-offline accounts, the settings, the log) lives in the scratch folder
  export XDG_DATA_HOME="$SCR/data" XDG_CONFIG_HOME="$SCR/config"
  : > "$SCR/start"

  # One attempt: $1 = its name, the rest = the renderer's arguments for godot. The log is $SCR/<name>.log; returns godot's exit code.
  attempt() {
    local name=$1 t0=$SECONDS code; shift
    echo "qa_shots: rendering with $name"
    nice -n 10 xvfb-run -a -s "-screen 0 1280x800x24" "$GODOT" "$@" --path "$PROJECT" -- --dev-offline --class="$CLASS" --qa --shot-plan="$PLAN" --shots="$OUT" > "$SCR/$name.log" 2>&1
    code=$?
    echo "qa_shots: $name took $((SECONDS - t0)) s (exit $code)"
    return $code
  }
  made() { find "$OUT" -maxdepth 1 -name '*.png' -newer "$SCR/start" 2>/dev/null | wc -l; }

  rc=1
  fell=1
  if [ "${DM_QA_FALLBACK:-}" = force ]; then
    :
  elif [ ! -f "$ICD" ]; then
    echo "qa_shots: the software Vulkan driver (lavapipe) is not installed ($ICD)"
  else
    VK_ICD_FILENAMES=$ICD attempt vulkan --rendering-method forward_plus --rendering-driver vulkan
    rc=$?
    why=""
    if [ "$(made)" -eq 0 ] && ! grep -q "QA-SHOTS" "$SCR/vulkan.log"; then   # nothing came out and the game never reached its plan: the renderer did not start
      why=$(grep -m1 -E "(ERROR|WARNING).*(Vulkan|vkCreate|video card drivers|rendering driver|RenderingDevice)" "$SCR/vulkan.log" || true)
      if [ -z "$why" ] && [ "$rc" -gt 128 ]; then why="godot died with signal $((rc - 128)) before its first shot"; fi
    fi
    if [ -n "$why" ]; then echo "qa_shots: Vulkan could not start (${why:0:200})"; else fell=0; fi
  fi
  if [ "$fell" -eq 1 ]; then
    if [ "${DM_QA_FALLBACK:-}" = never ]; then
      echo "qa_shots: no fallback renderer was asked for (DM_QA_FALLBACK=never): no pictures"
      exit "$rc"
    fi
    used="OpenGL 3 Compatibility (the fallback renderer)"
    echo "qa_shots: the pictures use the fallback renderer (OpenGL 3, Compatibility): their colours, lights and shadows are not the game's Forward+"
    attempt opengl3 --rendering-method gl_compatibility --rendering-driver opengl3
    rc=$?
    log="$SCR/opengl3.log"
  else
    used="Vulkan Forward+ (software, lavapipe)"
    log="$SCR/vulkan.log"
  fi
  banner=$(grep -m1 -E "(Vulkan|OpenGL API) .* - (Forward\+|Compatibility|Mobile) - " "$log" || true)
  if [ -n "$banner" ]; then echo "qa_shots: renderer: ${banner:0:200}"; fi
  if [ "$fell" -eq 0 ] && [ -n "$banner" ] && [[ "$banner" != *"Forward+"* ]]; then   # godot may fall back to OpenGL 3 on its own when Vulkan will not start
    used="a fallback renderer (godot did not start Vulkan Forward+)"
    echo "qa_shots: the pictures use the fallback renderer (godot started on its own without Vulkan Forward+): their colours, lights and shadows are not the game's"
  fi
  [ -z "${DM_QA_LOG:-}" ] || cp "$log" "$DM_QA_LOG"
  grep -E "QA-SHOTS|SCRIPT ERROR|Parse Error" "$log" | head -60
  if [ "$rc" -ne 0 ]; then echo "qa_shots: godot exited $rc"; tail -15 "$log"; fi
  echo "qa_shots: $(made) picture(s) in $OUT, rendered with $used"
  exit "$rc"
fi

# ---- the outer part: the checks, then the lock, the time limit and the render
case "${1:-}" in -h|--help) sed -n '2,13p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0;; esac
PLAN=${1:-}
OUT=${2:-}
CLASS=${3:-}
[ -n "$OUT" ] || { echo "usage: client/tools/qa_shots.sh <plan.json> <out_dir> [class]" >&2; exit 2; }
[ -f "$PLAN" ] && [ ! -L "$PLAN" ] || { echo "qa_shots: no plan file $PLAN" >&2; exit 2; }
[ "$(stat -c %s "$PLAN")" -le 65536 ] || { echo "qa_shots: the plan file is too big" >&2; exit 2; }
[ -f "$PROJECT/project.godot" ] || { echo "qa_shots: no project at $PROJECT" >&2; exit 2; }
if ! ls "$PROJECT"/bin/libdmcore.linux.*.so > /dev/null 2>&1 || [ ! -d "$PROJECT/.godot/imported" ]; then
  echo "qa_shots: this checkout is not set up: run 'bash tools/check/prep.sh' once (the combat core, the import and the crowd's models)" >&2
  exit 2
fi
[ -x "$GODOT" ] || { echo "qa_shots: no godot at $GODOT (GODOT=...)" >&2; exit 2; }
mkdir -p "$OUT" || exit 2
PLAN=$(realpath "$PLAN")
OUT=$(realpath "$OUT")
if [ -z "$CLASS" ]; then   # the plan's discipline -> its class number (client/main/qa_ui_shots.gd DISCIPLINES is the same table)
  CLASS=$(python3 - "$PLAN" <<'PY'
import json, sys
names = {"ossuary": 1, "gravecaller": 2, "mourner": 3, "rotweaver": 4, "reaper": 11}
try:
    d = json.load(open(sys.argv[1])).get("discipline")
except Exception:
    d = None
if isinstance(d, str):
    d = names.get(d.lower().removeprefix("hero_"))
print(d if d in names.values() else 2)
PY
)
fi
case "$CLASS" in [0-9]|[0-9][0-9]) ;; *) echo "qa_shots: the class must be a number (1-4 or 11), not '$CLASS'" >&2; exit 2;; esac
[ -d "$PROJECT/assets/crowd/baked" ] || echo "qa_shots: note: the crowd's models are not baked (bash tools/check/prep.sh): enemies and thralls would not be drawn"

if [ "${DM_QA_LOCKED:-}" = 1 ]; then
  timeout -k 20 "$LIMIT" bash "$SELF" --render "$PLAN" "$OUT" "$CLASS"
else
  echo "qa_shots: waiting for the renderer lock ($LOCK)"
  flock -w 900 -E 75 "$LOCK" timeout -k 20 "$LIMIT" bash "$SELF" --render "$PLAN" "$OUT" "$CLASS"
fi
rc=$?
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then echo "qa_shots: timed out after $LIMIT seconds"; fi
if [ "$rc" -eq 75 ]; then echo "qa_shots: the renderer lock was not free after 15 minutes"; fi
exit "$rc"
