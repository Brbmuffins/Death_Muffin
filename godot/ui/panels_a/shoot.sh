#!/usr/bin/env bash
# Screenshot panels-A gallery pages under Xvfb + llvmpipe, holding the one-renderer lock.
# usage: ui/panels_a/shoot.sh [pages|all] [outdir] [WxH]     e.g.  shoot.sh ascension,class shots/panels_a 1280x900
set -euo pipefail
cd "$(dirname "$0")/../.."
PAGES="${1:-all}"; DIR="${2:-$PWD/shots/panels_a}"; RES="${3:-1280x900}"
mkdir -p "$DIR"
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 \
  xvfb-run -a -s "-screen 0 ${RES}x24" \
  /home/ubuntu/tools/godot/godot --rendering-driver opengl3 --resolution "$RES" --path . res://ui/panels_a/gallery.tscn -- --pages="$PAGES" --dir="$DIR" --w="${RES%x*}" --h="${RES#*x}"
