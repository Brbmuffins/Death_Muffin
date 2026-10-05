#!/usr/bin/env bash
# usage: tests/world_fx/backdrop_shot.sh [out.png] [--mouse=x,y]   (one renderer at a time)
cd "$(dirname "$0")/../.."
OUT="${1:-$PWD/shots/world_fx/backdrop.png}"; shift || true
mkdir -p "$(dirname "$OUT")"
flock -w 3000 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x800x24" \
  timeout 600 /home/ubuntu/tools/godot/godot --path . --rendering-driver opengl3 --resolution 1280x800 --script res://tests/world_fx/backdrop_shot.gd -- --out="$OUT" "$@" 2>&1 | grep -E "backdrop|ERROR|SCRIPT|SHADER"
