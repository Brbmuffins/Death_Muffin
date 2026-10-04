#!/usr/bin/env bash
# Counsel card + glow over the HUD gallery mock, under the renderer lock (one renderer on the VPS at a time).
# usage: tools/godot/shoot-onboarding.sh <tip id> [out.png] [WxH] [calm|combat]
set -euo pipefail
cd "$(dirname "$0")/../../godot"
TIP="${1:-wave}"; OUT="${2:-$PWD/shots/onboarding/$TIP.png}"; RES="${3:-1280x800}"; PAGE="${4:-calm}"
mkdir -p "$(dirname "$OUT")"
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 \
  xvfb-run -a -s "-screen 0 ${RES}x24" \
  timeout 150 /home/ubuntu/tools/godot/godot --rendering-driver opengl3 --resolution "$RES" --path . res://ui/onboarding/onboarding_gallery.tscn -- --tip="$TIP" --page="$PAGE" --out="$OUT" ${SHOOT_EXTRA:-}
