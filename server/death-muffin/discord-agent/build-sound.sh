#!/usr/bin/env bash
# The agent's way to turn a generated ElevenLabs take into a game file (no keys, no network, nothing outside the worktree is writable).
#   build-sound.sh <id> [take]      run from the worktree root after the runner said the sound is ready; take = 1..4 (default 1)
# Same sandbox as check-godot.sh (sandbox-lib.sh). Reads audio-src/eleven/<id>/v<take>.mp3 (git-ignored raw take); sound-build.mjs, inside the
# sandbox, levels it to the game's loudness, writes godot/assets/audio/eleven/<id>.wav (sfx) or .mp3 (music) and the sound's row in
# docs/AUDIO-SOURCES.md (the licence record). The kind comes from audio-manifest/eleven/<id>.json. Godot writes the .import file the next time it
# imports (check-godot.sh does); commit it, the sound and docs/AUDIO-SOURCES.md.
set -uo pipefail
ID=${1:-}; TAKE=${2:-1}
[[ "$ID" =~ ^[a-z0-9_]{3,40}$ ]] && [[ "$TAKE" =~ ^[1-4]$ ]] || { echo "usage: build-sound.sh <id> [take 1-4]"; exit 2; }
TOP=$(git rev-parse --show-toplevel) || exit 2
SRC="audio-src/eleven/$ID/v$TAKE.mp3"; SPEC="audio-manifest/eleven/$ID.json"
for p in audio-src audio-src/eleven "audio-src/eleven/$ID" "$SRC" godot/assets/audio godot/assets/audio/eleven docs docs/AUDIO-SOURCES.md; do [ -L "$TOP/$p" ] && { echo "$p is a symlink"; exit 2; }; done
[ -f "$TOP/$SRC" ] || { echo "no take $TAKE for $ID yet ($SRC missing)"; exit 2; }
KIND=$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(j.kind==="music"?"music":"sfx")}catch{console.log("sfx")}' "$TOP/$SPEC")
TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export DM_SANDBOX_LIB="$TOOLS/sandbox-lib.sh"
export TOP ID TAKE KIND TOOLS
export DM_PAYLOAD='
  set -uo pipefail
  cd "$TOP"
  node "$TOOLS/sound-build.mjs" "$ID" "$TAKE" "$KIND"
'
timeout -k 10 120 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
