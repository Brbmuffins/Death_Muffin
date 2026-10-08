#!/usr/bin/env bash
# usage: game_ui/shoot.sh <hud|inventory|sheet|grimoire|atlas|settings|codex|acre|legion> [out.png] [WxH]
set -euo pipefail
cd "$(dirname "$0")/.."
PAGE="${1:-hud}"; OUT="${2:-$PWD/shots/game_ui/$PAGE.png}"; RES="${3:-1280x800}"
mkdir -p "$(dirname "$OUT")"
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 \
  xvfb-run -a -s "-screen 0 ${RES}x24" \
  timeout 150 /home/ubuntu/tools/godot/godot --rendering-driver opengl3 --resolution "$RES" --path . res://game_ui/shoot.tscn -- --page="$PAGE" --out="$OUT" ${SHOOT_EXTRA:-}
