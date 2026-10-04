#!/usr/bin/env bash
# Capture a HUD gallery page under Xvfb + llvmpipe (one renderer on the VPS at a time).
# SHOOT_EXTRA='--crop=x,y,w,h,scale' makes a zoomed detail shot.
# usage: ui/hud/shoot.sh <combat|boss|calm|death|events> [out.png] [WxH]
set -euo pipefail
cd "$(dirname "$0")/../.."
PAGE="${1:-combat}"; OUT="${2:-$PWD/shots/hud/$PAGE.png}"; RES="${3:-1280x800}"
mkdir -p "$(dirname "$OUT")"
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 \
  xvfb-run -a -s "-screen 0 ${RES}x24" \
  timeout 150 /home/ubuntu/tools/godot/godot --rendering-driver opengl3 --resolution "$RES" --path . res://ui/hud/hud_gallery.tscn -- --page="$PAGE" --out="$OUT" ${SHOOT_EXTRA:-}
