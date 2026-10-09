#!/usr/bin/env bash
# Godot-mode counterpart of shot.sh: screenshots of the agent's branch UI. usage: shot-godot.sh [plan.json]   (default .dm-shot.json in the worktree;
# the plan format is documented in godot/main/qa_ui_shots.gd and PROMPT-godot.md: up to 4 shots of windows / tooltips on the offline demo hero).
# Same sandbox as check-godot.sh (sandbox-lib.sh): fresh user/network/mount namespaces, no network (loopback only), the WHOLE filesystem read-only, a private /tmp,
# only the worktree writable; HOME and the XDG dirs are a fresh temp dir so Godot's user:// never touches the real home. Inside: an Xvfb screen and the branch's
# own Godot client in software GL (`--offline --world-demo --qa --shot-plan=...`) write raw PNGs to <worktree>/.dm-shots/.raw/. Outside the sandbox (this script, trusted
# code), label-shot.py burns "BRANCH PREVIEW · not live · <branch>" into every one and writes <worktree>/.dm-shots/<name>.png (an image that could not be labelled is
# never published). One renderer at a time across all agents (the VPS's software GL is heavy): the shared qa-browser.lock, and a hard 15 minute limit.
# Env: GODOT (default /home/ubuntu/tools/godot/godot), DM_BROWSER_LOCK, DM_SHOT_LABEL_PY (tests).
set -uo pipefail
TOP=$(git rev-parse --show-toplevel) || exit 2
TOOLS=$(cd "$(dirname "$0")" && pwd)
FILE=${1:-.dm-shot.json}
case "$FILE" in /*|*..*) echo "the plan must be a file inside the worktree"; exit 2;; esac
[ -f "$TOP/$FILE" ] && [ ! -L "$TOP/$FILE" ] || { echo "no plan file $FILE in the worktree (see the prompt for the format)"; exit 2; }
[ "$(stat -c %s "$TOP/$FILE")" -le 65536 ] || { echo "plan file is too big"; exit 2; }
[ -d "$TOP/godot" ] || { echo "no godot/ project in this worktree"; exit 2; }
DM_SHOT_BRANCH=$(git -C "$TOP" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
export TOP TOOLS FILE DM_SHOT_BRANCH GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
export DM_SANDBOX_LIB="$TOOLS/sandbox-lib.sh"
LOCK=${DM_BROWSER_LOCK:-/home/ubuntu/death-muffin/qa-browser.lock}
RAW="$TOP/.dm-shots/.raw"
[ -L "$TOP/.dm-shots" ] && { echo ".dm-shots must not be a symlink"; exit 2; }
rm -rf "$RAW" 2>/dev/null; mkdir -p "$RAW" || exit 2
export DM_PAYLOAD='
  set -uo pipefail
  SCR=$(mktemp -d /tmp/dmshot.XXXXXX)    # inside the private /tmp: gone when the sandbox exits
  export HOME="$SCR/home" XDG_DATA_HOME="$SCR/data" XDG_CONFIG_HOME="$SCR/config" XDG_CACHE_HOME="$SCR/cache"
  mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
  cd "$TOP"
  if [ ! -d godot/.godot/imported ]; then      # fresh worktree: import the project once (git-ignored cache, written into the worktree)
    echo "== importing the project"
    "$GODOT" --headless --path godot --import > "$SCR/import.log" 2>&1 || true
    [ -d godot/.godot/imported ] || { tail -15 "$SCR/import.log"; echo "godot import failed"; exit 1; }
  fi
  echo "== rendering"
  /usr/bin/time -f "render: cpu=%P wall=%es maxrss=%MKB" xvfb-run -a -s "-screen 0 1280x800x24" "$GODOT" --rendering-driver opengl3 --path godot -- \
    --offline --world-demo --qa --shot-plan="$TOP/$FILE" --shots="$TOP/.dm-shots/.raw" > "$SCR/render.log" 2>&1
  rc=$?
  grep -E "QA-SHOTS|SCRIPT ERROR|Parse Error|^render:" "$SCR/render.log" | head -40
  [ $rc -eq 0 ] || { echo "godot exited $rc"; tail -15 "$SCR/render.log"; }
  exit $rc
'   # the sandboxed work; run by dm_sandbox_run inside the nested namespace (sandbox-lib.sh)
flock -w 900 "$LOCK" timeout -k 20 900 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
[ $rc -eq 124 ] || [ $rc -eq 137 ] && echo "screenshots timed out after 15 minutes"
# trusted post-processing (outside the sandbox): label every raw image, then drop the raw folder. Even a partial run labels what it produced.
python3 "${DM_SHOT_LABEL_PY:-$TOOLS/label-shot.py}" "$TOP" "$DM_SHOT_BRANCH"; lrc=$?
rm -rf "$RAW" 2>/dev/null
[ $lrc -eq 0 ] || exit 3
exit $rc
