#!/usr/bin/env bash
# Screenshots for the UI parity wave, ALL pages under ONE renderer-lock acquisition (Xvfb + llvmpipe, one renderer on the VPS at a time).
# usage: tests/ui_parity/shoot.sh [page ...]      pages: tip_spell tip_item belt_picker bug settings hud login register select
# Output: godot/shots/ui_parity/<page>.png (gitignored). Compare against the web with the Playwright script in the report.
set -euo pipefail
cd "$(dirname "$0")/../.."
PAGES=("$@"); [ ${#PAGES[@]} -eq 0 ] && PAGES=(tip_spell tip_item belt_picker bug settings hud login register)
OUT="$PWD/shots/ui_parity"; mkdir -p "$OUT"
G=/home/ubuntu/tools/godot/godot
flock -w 3000 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 bash -c '
for p in "$@"; do
  case "$p" in
    login|register|select)
      xvfb-run -a -s "-screen 0 1280x800x24" timeout 150 '"$G"' --rendering-driver opengl3 --resolution 1280x800 --path . res://front/front_shoot.tscn -- --page="$p" --out="'"$OUT"'/$p.png" >/dev/null 2>&1 || echo "FAILED $p" ;;
    *)
      xvfb-run -a -s "-screen 0 1280x800x24" timeout 150 '"$G"' --rendering-driver opengl3 --resolution 1280x800 --path . res://game_ui/shoot.tscn -- --page="$p" --out="'"$OUT"'/$p.png" >/dev/null 2>&1 || echo "FAILED $p" ;;
  esac
done' _ "${PAGES[@]}"
ls "$OUT"
