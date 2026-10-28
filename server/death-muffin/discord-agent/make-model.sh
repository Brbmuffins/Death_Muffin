#!/usr/bin/env bash
# The agent's Blender steps on a model made from a ComfyUI run (guides/models.md, ASSET_PIPELINE.md "Image to model"), run from the worktree root:
#   make-model.sh fit <id> --stand [--yaw D] [--height M] [--max-tilt D]     the game placement of a new subject (written as the record's frame)
#   make-model.sh fit <id> --ref <model.glb> [--tilt-min D] [--max-tilt D]   ... or fitted onto an older model of the same subject (a file in the worktree)
#   make-model.sh build <id> [--from N]                                      the record's steps on the run's model -> art-src/comfy/<id>/<game file>
#   make-model.sh kinds                                                      what each step does and takes
# Runs the worktree's tools/blender/make.mjs (the record art-manifest/comfy/<id>.json, the run's model in art-src/comfy/<id>/) inside the same
# sandbox as check-godot.sh (sandbox-lib.sh: no network, no keys, read-only filesystem, only the worktree writable). fit also writes the placed
# model as art-src/comfy/<id>/work/fit.glb, to check with render-model.sh. One renderer at a time with the screenshots and model renders (the
# shared qa-browser.lock); 15 minute limit. Env: BLENDER (default /home/ubuntu/tools/blender/blender), DM_BROWSER_LOCK.
set -uo pipefail
TOP=$(git rev-parse --show-toplevel) || exit 2
TOOLS=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: make-model.sh fit <id> --stand [--yaw D] [--height M] [--max-tilt D] | fit <id> --ref <model.glb> [--tilt-min D] [--max-tilt D] | build <id> [--from N] | kinds"; exit 2; }
CMD=${1:-}; NUM='^-?[0-9]+([.][0-9]+)?$'
case "$CMD" in
  kinds) [ $# -eq 1 ] || usage;;
  fit|build)
    [[ "${2:-}" =~ ^[a-z0-9_]{3,40}$ ]] || usage
    for p in art-manifest art-manifest/comfy tools tools/blender art-src art-src/comfy "art-src/comfy/$2" "art-src/comfy/$2/work"; do [ -L "$TOP/$p" ] && { echo "$p is a symlink"; exit 2; }; done
    a=("${@:3}")
    for ((i = 0; i < ${#a[@]}; i++)); do
      case "$CMD ${a[i]}" in
        "fit --stand") ;;
        "fit --yaw"|"fit --height"|"fit --max-tilt"|"fit --tilt-min"|"build --from") [[ "${a[i + 1]:-}" =~ $NUM ]] || usage; i=$((i + 1));;
        "fit --ref")
          R=${a[i + 1]:-}
          [[ "$R" =~ ^(client/assets/slice/models|art-src/comfy)/[a-z0-9_/.-]+[.]glb$ ]] && [[ "$R" != *..* ]] || { echo "--ref takes a .glb under client/assets/slice/models/ or art-src/comfy/"; exit 2; }
          [ -f "$TOP/$R" ] && [ "$(realpath -m "$TOP/$R")" = "$TOP/$R" ] || { echo "no $R (or it goes through a symlink)"; exit 2; }
          i=$((i + 1));;
        *) usage;;
      esac
    done;;
  *) usage;;
esac
DM_SHOT_BRANCH=$(git -C "$TOP" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
export TOP MM_ARGS="$*" BLENDER="${BLENDER:-/home/ubuntu/tools/blender/blender}"
export DM_SANDBOX_LIB="$TOOLS/sandbox-lib.sh"
LOCK=${DM_BROWSER_LOCK:-/home/ubuntu/death-muffin/qa-browser.lock}
export DM_PAYLOAD='
  set -uo pipefail
  export HOME=$(mktemp -d /tmp/dmmake-home.XXXXXX)
  cd "$TOP"
  nice -n 10 node tools/blender/make.mjs $MM_ARGS
'
flock -w 900 "$LOCK" timeout -k 20 900 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
[ $rc -eq 124 ] || [ $rc -eq 137 ] && echo "make-model timed out after 15 minutes"
exit $rc
