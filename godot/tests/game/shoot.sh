#!/usr/bin/env bash
# Rendered QA run of the real game (offline demo world, scripted fight): shots in godot/shots/game/qa_NN.png. One renderer on the VPS at a time.
# usage: tests/game/shoot.sh [seconds=40] [extra user args...]
cd "$(dirname "$0")/../.."
SECONDS_RUN="${1:-40}"; shift || true
mkdir -p shots/game; rm -f shots/game/qa_*.png
exec flock -w 3000 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
  /home/ubuntu/tools/godot/godot --rendering-driver opengl3 --path . -- --offline --world-demo --qa --shots="$PWD/shots/game" --seconds="$SECONDS_RUN" "$@"
