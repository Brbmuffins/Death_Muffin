#!/usr/bin/env bash
# Automated Godot playtest (offline edition only). Isolated user:// so the real offline save is never touched.
# usage: tools/godot/playtest.sh [--rendered] [--disc=2] [--boss=gravedigger] [--scale=3] [--tag=NAME] [--sessionA-only]
# Output: godot/tests/playtest/out/<tag>/{A,B}.json + log. Headless by default; --rendered = xvfb + llvmpipe under the shared renderer lock.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT=/home/ubuntu/tools/godot/godot
DISC=2; BOSS=gravedigger; SCALE=3; RENDERED=0; TAG=""; ONLY_A=0
for a in "$@"; do case "$a" in
  --rendered) RENDERED=1;; --disc=*) DISC="${a#*=}";; --boss=*) BOSS="${a#*=}";; --scale=*) SCALE="${a#*=}";; --tag=*) TAG="${a#*=}";; --sessionA-only) ONLY_A=1;;
esac; done
TAG="${TAG:-d${DISC}_$([ $RENDERED = 1 ] && echo r || echo h)}"
OUT="$ROOT/godot/tests/playtest/out/$TAG"; rm -rf "$OUT"; mkdir -p "$OUT/xdg" "$OUT/shots"
export XDG_DATA_HOME="$OUT/xdg"   # user:// -> $OUT/xdg/godot/app_userdata/...
run() { # session
  local S=$1
  local ARGS=(--path "$ROOT/godot" --script res://tests/playtest/bot.gd)
  local UA=(-- --session=$S --disc=$DISC --boss=$BOSS --scale=$SCALE --name=$TAG --out="$OUT/$S.json" --shots="$OUT/shots")
  if [ $RENDERED = 1 ]; then
    flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 1500 xvfb-run -a -s "-screen 0 1280x800x24" $GODOT --rendering-driver opengl3 "${ARGS[@]}" "${UA[@]}" > "$OUT/$S.log" 2>&1
  else
    timeout 1500 $GODOT --headless "${ARGS[@]}" "${UA[@]}" > "$OUT/$S.log" 2>&1
  fi
  echo "session $S exit=$?"
}
run A
[ $ONLY_A = 1 ] || run B
grep -h "^PLAYTEST\|\[BUG" "$OUT"/A.log "$OUT"/B.log 2>/dev/null | head -80
