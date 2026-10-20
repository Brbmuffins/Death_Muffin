#!/usr/bin/env bash
# The agent's way to put a concept image into the game as one of its flat pictures (no keys, no network, nothing outside the worktree is writable).
#   build-picture.sh <kind> <name> <concept id> [--replace]    run from the worktree root once people picked the concept (DECISIONS B70)
# Same sandbox as check-godot.sh (sandbox-lib.sh). Runs the worktree's tools/pictures/build.mjs inside it: art-src/concepts/<concept id>.png ->
# <kind's folder>/<name>.webp at the kind's size and size limit (tools/pictures/kinds.json), a new picture's .import, and its record in
# art-manifest/images.json. --replace changes an existing picture (an edit of it). Godot completes the .import on its next import
# (check-godot.sh --rerun code_load); commit the picture, its .import and art-manifest/images.json, then point the game's data at it.
set -uo pipefail
KIND=${1:-}; NAME=${2:-}; SRC=${3:-}; REPLACE=${4:-}
if ! { [ $# -ge 3 ] && [ $# -le 4 ] && [[ "$KIND" =~ ^[a-z0-9_]{3,40}$ ]] && [[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]{1,47}$ ]] && [[ "$SRC" =~ ^[a-z0-9_]{3,40}$ ]] && { [ -z "$REPLACE" ] || [ "$REPLACE" = --replace ]; }; }; then
  echo "usage: build-picture.sh <kind> <name> <concept id> [--replace]   (kinds: tools/pictures/kinds.json)"; exit 2
fi
TOP=$(git rev-parse --show-toplevel) || exit 2
for p in art-src art-src/concepts "art-src/concepts/$SRC.png" art-manifest art-manifest/images.json tools tools/pictures; do [ -L "$TOP/$p" ] && { echo "$p is a symlink"; exit 2; }; done
[ -f "$TOP/art-src/concepts/$SRC.png" ] || { echo "no concept image $SRC (art-src/concepts/$SRC.png): ask for it with .dm-concept-request.json first"; exit 2; }
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export TOP KIND NAME SRC REPLACE
export DM_PAYLOAD='
  set -uo pipefail
  cd "$TOP"
  node tools/pictures/build.mjs "$KIND" "$NAME" "$SRC" ${REPLACE:+--replace}
'
timeout -k 10 120 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
