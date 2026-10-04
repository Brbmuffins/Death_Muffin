#!/usr/bin/env bash
# usage: tests/world/tour.sh  -> godot/shots/world/area_*.png (one renderer at a time)
cd "$(dirname "$0")/../.."
mkdir -p shots/world
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x800x24" /home/ubuntu/tools/godot/godot --path . --rendering-driver opengl3 -- --qa --tour --shots=$PWD/shots/world "$@" > shots/world/log.txt 2>&1
tail -3 shots/world/log.txt
