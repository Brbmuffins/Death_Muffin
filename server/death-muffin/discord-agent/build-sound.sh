#!/usr/bin/env bash
# The agent's way to turn a generated ElevenLabs take into a game file (no keys, no network, nothing outside the worktree is writable).
#   build-sound.sh <id> [take]      run from the worktree root after the runner said the sound is ready; take = 1..4 (default 1)
# Same sandbox as check-godot.sh (sandbox-lib.sh). Reads audio-src/eleven/<id>/v<take>.mp3 (git-ignored raw take) and writes:
#   sfx    godot/assets/audio/eleven/<id>.wav   mono 16-bit 44.1 kHz (one-shots start for free as QOA, like esm/; see godot/audio/README.md)
#   music  godot/assets/audio/eleven/<id>.mp3   copied as-is (Godot imports MP3)
# The kind comes from audio-manifest/eleven/<id>.json. Godot writes the .import file the next time it imports (check-godot.sh does); commit it too.
set -uo pipefail
ID=${1:-}; TAKE=${2:-1}
[[ "$ID" =~ ^[a-z0-9_]{3,40}$ ]] && [[ "$TAKE" =~ ^[1-4]$ ]] || { echo "usage: build-sound.sh <id> [take 1-4]"; exit 2; }
TOP=$(git rev-parse --show-toplevel) || exit 2
SRC="audio-src/eleven/$ID/v$TAKE.mp3"; SPEC="audio-manifest/eleven/$ID.json"
for p in audio-src audio-src/eleven "audio-src/eleven/$ID" "$SRC" godot/assets/audio godot/assets/audio/eleven; do [ -L "$TOP/$p" ] && { echo "$p is a symlink"; exit 2; }; done
[ -f "$TOP/$SRC" ] || { echo "no take $TAKE for $ID yet ($SRC missing)"; exit 2; }
KIND=$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(j.kind==="music"?"music":"sfx")}catch{console.log("sfx")}' "$TOP/$SPEC")
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export TOP ID SRC KIND
export DM_PAYLOAD='
  set -uo pipefail
  cd "$TOP"
  mkdir -p godot/assets/audio/eleven
  if [ "$KIND" = music ]; then DST="godot/assets/audio/eleven/$ID.mp3"; cp "$SRC" "$DST" || exit 1
  else DST="godot/assets/audio/eleven/$ID.wav"; ffmpeg -nostdin -loglevel error -y -i "$SRC" -ac 1 -ar 44100 -c:a pcm_s16le "$DST" || { echo "ffmpeg failed"; exit 1; }; fi
  printf "%s %s s\n" "$DST" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DST")"
  echo "BUILT: $DST"
'
timeout -k 10 120 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
