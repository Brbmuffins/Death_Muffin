#!/usr/bin/env bash
# Godot-mode counterpart of shot.sh: screenshots of the agent's branch. usage: shot-godot.sh [plan.json]   (default .dm-shot.json in the worktree;
# the plan format is documented in client/main/qa_ui_shots.gd and PROMPT-godot.md: up to 4 shots of windows / tooltips / the hero wearing gear on the offline demo hero;
# a plan "discipline" (ossuary|gravecaller|mourner|rotweaver|reaper, or the class number) picks the necromancer: it is mapped here to `--class=N`, default 2).
# Same sandbox as check-godot.sh (sandbox-lib.sh): fresh user/network/mount namespaces, no network (loopback only), the WHOLE filesystem read-only, a private /tmp,
# only the worktree writable; HOME and the XDG dirs are a fresh temp dir so Godot's user:// never touches the real home. Two sandboxed runs: the game's build
# products (prep.sh --warm of the base revision outside, then prep.sh --read-only inside: the combat core, the import, the crowd's bakes), then the branch's own client/tools/qa_shots.sh
# (Forward+ on the software Vulkan driver, the OpenGL 3 fallback with a line saying so) writes raw PNGs to <worktree>/.dm-shots/.raw/. Outside the sandbox
# (this script, trusted code), label-shot.py burns "BRANCH PREVIEW · not live · <branch>" into every one and writes <worktree>/.dm-shots/<name>.png (an image
# that could not be labelled is never published). One renderer at a time across all agents (the shared qa-browser.lock, held for the rendering only), and a
# hard 15 minute limit on it.
# Env: GODOT (default /home/ubuntu/tools/godot/godot), DM_BROWSER_LOCK, DM_SHOT_LABEL_PY (tests), DM_BUILD_CACHE (prep.sh), DM_PREP
# (tests: a stand-in for prep.sh).
set -uo pipefail
TOP=$(git rev-parse --show-toplevel) || exit 2
TOOLS=$(cd "$(dirname "$0")" && pwd)
FILE=${1:-.dm-shot.json}
case "$FILE" in /*|*..*) echo "the plan must be a file inside the worktree"; exit 2;; esac
[ -f "$TOP/$FILE" ] && [ ! -L "$TOP/$FILE" ] || { echo "no plan file $FILE in the worktree (see the prompt for the format)"; exit 2; }
[ "$(stat -c %s "$TOP/$FILE")" -le 65536 ] || { echo "plan file is too big"; exit 2; }
[ -f "$TOP/client/project.godot" ] || { echo "no client/ project in this worktree"; exit 2; }
DM_SHOT_BRANCH=$(git -C "$TOP" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
# the plan's discipline -> class index (client/data/combat/disciplines.json by_index; DmQaUiShots.DISCIPLINES is the same table), read here outside the sandbox
DM_SHOT_CLASS=$(python3 - "$TOP/$FILE" <<'PY'
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
case "$DM_SHOT_CLASS" in [0-9]|[0-9][0-9]) ;; *) DM_SHOT_CLASS=2;; esac
export TOP TOOLS FILE DM_SHOT_BRANCH DM_SHOT_CLASS GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
export DM_SANDBOX_LIB="$TOOLS/sandbox-lib.sh"
LOCK=${DM_BROWSER_LOCK:-/home/ubuntu/death-muffin/qa-browser.lock}
RAW="$TOP/.dm-shots/.raw"
[ -L "$TOP/.dm-shots" ] && { echo ".dm-shots must not be a symlink"; exit 2; }
rm -rf "$RAW" 2>/dev/null; mkdir -p "$RAW" || exit 2
# the game's build products: the cache outside (trusted), the copy and whatever this branch changed inside the sandbox
# the installed agent keeps its trusted copy beside this script; run from a checkout (team-release.sh), the checkout's own one
DM_PREP="${DM_PREP:-$TOOLS/prep.sh}"; [ -f "$DM_PREP" ] || DM_PREP="$(cd "$TOOLS/../../.." && pwd)/tools/check/prep.sh"; export DM_PREP
# (never filled from the job's own code: without a base revision the sandbox builds what is missing and stores nothing)
MB=$(git -C "$TOP" merge-base HEAD "origin/${BASE_BRANCH:-main}" 2>/dev/null) || MB=
if [ -n "$MB" ]; then PREP=$(bash "$DM_PREP" --warm "$MB" "$TOP" 2>&1) || { echo "$PREP" | tail -20; echo "preparing the game for the pictures failed (prep.sh --warm)"; rm -rf "$RAW"; exit 1; }; fi
sandboxed() {   # $1 = the payload; the sandbox's own scratch folder and user folders
  DM_PAYLOAD='
  set -uo pipefail
  SCR=$(mktemp -d /tmp/dmshot.XXXXXX)    # inside the private /tmp: gone when the sandbox exits
  export SCR HOME="$SCR/home" XDG_DATA_HOME="$SCR/data" XDG_CONFIG_HOME="$SCR/config" XDG_CACHE_HOME="$SCR/cache"
  mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
  cd "$TOP"
  '"$1" timeout -k 20 "$2" unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
}
sandboxed 'bash "$DM_PREP" --read-only "$TOP"' 1500 || { echo "preparing the game for the pictures failed"; rm -rf "$RAW"; exit 1; }
exec 6>>"$LOCK"
flock -w 900 6 || { echo "the renderer stayed busy for 15 minutes (another agent's pictures)"; rm -rf "$RAW"; exit 1; }
sandboxed 'echo "== rendering"; DM_QA_LOCKED=1 DM_QA_LIMIT=840 bash client/tools/qa_shots.sh "$TOP/$FILE" "$TOP/.dm-shots/.raw" "$DM_SHOT_CLASS"' 900
rc=$?
flock -u 6
[ $rc -eq 124 ] || [ $rc -eq 137 ] && echo "screenshots timed out after 15 minutes"
# trusted post-processing (outside the sandbox): label every raw image, then drop the raw folder. Even a partial run labels what it produced.
python3 "${DM_SHOT_LABEL_PY:-$TOOLS/label-shot.py}" "$TOP" "$DM_SHOT_BRANCH"; lrc=$?
rm -rf "$RAW" 2>/dev/null
[ $lrc -eq 0 ] || exit 3
exit $rc
