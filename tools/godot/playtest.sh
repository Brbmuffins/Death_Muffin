#!/usr/bin/env bash
# Automated Godot playtest (dev-offline mode only). Isolated user:// so the real offline save is never touched.
# usage: tools/godot/playtest.sh [--next] [--rendered] [--disc=2] [--boss=gravedigger] [--scale=3] [--tag=NAME] [--sessionA-only]
# The bot (tests/playtest/bot_next.gd) drives the one game, the rebuild (DmNextGame); outputs go to out/<tag>.
# Output: godot/tests/playtest/out/<tag>/{A,B}.json + log. Headless by default; --rendered = xvfb + llvmpipe under the shared renderer lock.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT=/home/ubuntu/tools/godot/godot
DELAY=0; SKIP=""; DISC=2; BOSS=gravedigger; SCALE=3; RENDERED=0; TAG=""; ONLY_A=0; NEXT=0
for a in "$@"; do case "$a" in
  --rendered) RENDERED=1;; --next) NEXT=1;; --disc=*) DISC="${a#*=}";; --boss=*) BOSS="${a#*=}";; --scale=*) SCALE="${a#*=}";; --tag=*) TAG="${a#*=}";; --sessionA-only) ONLY_A=1;; --skip-to=*) SKIP="${a#*=}";; --delay=*) DELAY="${a#*=}";;
esac; done
TAG="${TAG:-$([ $NEXT = 1 ] && echo n)d${DISC}_$([ $RENDERED = 1 ] && echo r || echo h)}"
# One game since 2026-10-09: the bot always drives DmNextGame on the dev-offline backend (--next is still accepted, it changes nothing).
BOT=bot_next.gd; EXTRA=(--dev-offline); WARM=--warmup; NEXT=1
OUT="$ROOT/godot/tests/playtest/out/$TAG"; rm -rf "$OUT"; mkdir -p "$OUT/xdg" "$OUT/shots"
export XDG_DATA_HOME="$OUT/xdg"   # user:// -> $OUT/xdg/godot/app_userdata/...
run() { # session
  local S=$1
  local ARGS=(--path "$ROOT/godot" --script res://tests/playtest/$BOT)
  local UA=(-- --session=$S --disc=$DISC --boss=$BOSS --scale=$SCALE --name=$TAG $WARM --skip-to=$SKIP --delay=$DELAY --out="$OUT/$S.json" --shots="$OUT/shots" "${EXTRA[@]}")
  if [ $RENDERED = 1 ]; then
    flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 1500 xvfb-run -a -s "-screen 0 1280x800x24" $GODOT --rendering-driver opengl3 "${ARGS[@]}" "${UA[@]}" > "$OUT/$S.log" 2>&1
  else
    timeout 1500 $GODOT --headless "${ARGS[@]}" "${UA[@]}" > "$OUT/$S.log" 2>&1
  fi
  echo "session $S exit=$?"
}
# refresh the class cache/import when the tree changed (a merge adds class_names the cache does not know yet)
STAMP="$ROOT/godot/.godot/playtest_import_stamp"; CUR="$(git -C "$ROOT" rev-parse HEAD)$(git -C "$ROOT" status --short godot | md5sum | cut -c1-8)"
if [ "$(cat "$STAMP" 2>/dev/null)" != "$CUR" ]; then timeout 600 $GODOT --headless --path "$ROOT/godot" --import > "$OUT/import.log" 2>&1; echo "$CUR" > "$STAMP"; fi
run A
[ $ONLY_A = 1 ] || run B
grep -h "^PLAYTEST\|\[BUG" "$OUT"/A.log "$OUT"/B.log 2>/dev/null | head -80
