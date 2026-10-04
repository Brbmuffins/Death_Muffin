#!/usr/bin/env bash
# Capture a DmFx gallery page under Xvfb + llvmpipe (one renderer on the VPS at a time).
# usage: fx/shoot.sh <page> [out.png] [t1,t2,...] [extra gallery args...]      e.g. fx/shoot.sh 0 shots/fx/p0.png 0.5,1.2 --per=16
set -euo pipefail
cd "$(dirname "$0")/.."
PAGE="${1:-0}"; OUT="${2:-$PWD/shots/fx/page_$PAGE.png}"; T="${3:-0.6}"; shift 3 || true
mkdir -p "$(dirname "$OUT")"
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 \
  xvfb-run -a -s "-screen 0 1280x800x24" timeout "${FX_TIMEOUT:-240}" \
  /home/ubuntu/tools/godot/godot --rendering-driver opengl3 --resolution 1280x800 --fixed-fps 30 --path . res://fx/gallery.tscn -- --page="$PAGE" --out="$OUT" --t="$T" "$@"
