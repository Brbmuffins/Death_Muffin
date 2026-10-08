#!/usr/bin/env bash
# usage: tests/perf/lighting_shot.sh --shots=/abs/dir --tag=before [--graphics=high] [--areas=a,b] [--brightness=1.0]   (one renderer at a time)
cd "$(dirname "$0")/../.."
${LOCK_CMD-flock -w 3000 /home/ubuntu/death-muffin/qa-browser.lock} nice -n 10 xvfb-run -a -s "-screen 0 1280x800x24" \
  timeout 900 /home/ubuntu/tools/godot/godot --path . --rendering-driver opengl3 --resolution 1280x800 --script res://tests/perf/lighting_shot.gd -- "$@" 2>&1 | grep -E "STATS|RETRY|SCRIPT ERROR"
