#!/usr/bin/env bash
# The agent's Blender jobs on the game's models (DECISIONS B74, guides/blender.md): blender-job.sh   (run from the worktree root)
# Reads the job from .dm-blender.json in the worktree ({"model": "<id>", "steps": [{"kind": ...}, ...]}, kinds: tools/blender/kinds.json) and runs
# the worktree's tools/blender/jobs.mjs inside the same sandbox as check-godot.sh (sandbox-lib.sh: no network, no keys, read-only filesystem,
# only the worktree writable). The job changes the model, its rows and its record (art-manifest/blender/<id>.json) in the worktree; its preview
# sheet (the touched clips in motion, or the model before and after) goes through label-shot.py (trusted, outside the sandbox), which burns
# "BRANCH PREVIEW · not live" in and writes .dm-shots/blender-<id>.png; the runner posts it in the thread after the turn. One renderer at a
# time with the screenshots and model renders (the shared qa-browser.lock), 10 minute limit.
# Env: BLENDER (default /home/ubuntu/tools/blender/blender), DM_BROWSER_LOCK, DM_SHOT_LABEL_PY (tests).
set -uo pipefail
[ $# -eq 0 ] || { echo "usage: blender-job.sh   (the job is .dm-blender.json in the worktree root)"; exit 2; }
TOP=$(git rev-parse --show-toplevel) || exit 2
TOOLS=$(cd "$(dirname "$0")" && pwd)
JOB="$TOP/.dm-blender.json"
for p in .dm-blender.json tools tools/blender art-manifest; do [ -L "$TOP/$p" ] && { echo "$p is a symlink"; exit 2; }; done
[ -f "$JOB" ] || { echo "no job: write .dm-blender.json first ({\"model\": \"<id>\", \"steps\": [...]}, kinds: tools/blender/kinds.json)"; exit 2; }
DM_SHOT_BRANCH=$(git -C "$TOP" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
export TOP JOB BLENDER="${BLENDER:-/home/ubuntu/tools/blender/blender}"
export DM_SANDBOX_LIB="$TOOLS/sandbox-lib.sh"
LOCK=${DM_BROWSER_LOCK:-/home/ubuntu/death-muffin/qa-browser.lock}
RAW="$TOP/.dm-shots/.raw"
[ -L "$TOP/.dm-shots" ] && { echo ".dm-shots must not be a symlink"; exit 2; }
rm -rf "$RAW" 2>/dev/null; mkdir -p "$RAW" || exit 2
export DM_PAYLOAD='
  set -uo pipefail
  export HOME=$(mktemp -d /tmp/dmblender-home.XXXXXX)
  cd "$TOP"
  nice -n 10 node tools/blender/jobs.mjs run "$JOB" --shots "$TOP/.dm-shots/.raw"
'
flock -w 900 "$LOCK" timeout -k 20 600 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
[ $rc -eq 124 ] || [ $rc -eq 137 ] && echo "the job timed out after 10 minutes (nothing was written unless CHANGED was printed)"
python3 "${DM_SHOT_LABEL_PY:-$TOOLS/label-shot.py}" "$TOP" "$DM_SHOT_BRANCH"; lrc=$?
rm -rf "$RAW" 2>/dev/null
[ $lrc -eq 0 ] || exit 3
exit $rc
