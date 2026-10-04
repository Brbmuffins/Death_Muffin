#!/usr/bin/env bash
# Capture a UI gallery page under Xvfb + llvmpipe (one renderer on the VPS at a time).
# usage: ui/shoot.sh <page> [out.png] [WxH]      pages: widgets settings reliquary tabbed scrolled
set -euo pipefail
cd "$(dirname "$0")/.."
PAGE="${1:-widgets}"; OUT="${2:-$PWD/shots/ui/$PAGE.png}"; RES="${3:-1280x800}"
mkdir -p "$(dirname "$OUT")"
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 \
  xvfb-run -a -s "-screen 0 ${RES}x24" \
  /home/ubuntu/tools/godot/godot --rendering-driver opengl3 --resolution "$RES" --path . res://ui/gallery.tscn -- --page="$PAGE" --out="$OUT" ${SHOOT_EXTRA:-}
