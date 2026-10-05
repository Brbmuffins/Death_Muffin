#!/usr/bin/env bash
# usage: tests/world_fx/bench.sh [--areas=nave,fen] [--features=nave] [--frames=45] [--out=/abs/dir]  (one renderer at a time)
cd "$(dirname "$0")/../.."
OUT=$PWD/shots/world_fx
for a in "$@"; do case $a in --out=*) OUT="${a#--out=}";; esac; done
mkdir -p "$OUT"
flock -w 3000 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x800x24" \
  timeout 1500 /home/ubuntu/tools/godot/godot --path . --rendering-driver opengl3 --resolution 1280x800 --script res://tests/world_fx/bench.gd -- --out="$OUT" "$@" > "$OUT/log.txt" 2>&1
grep -E "bench|ERROR|SCRIPT|SHADER|Parse" "$OUT/log.txt" | head -80
