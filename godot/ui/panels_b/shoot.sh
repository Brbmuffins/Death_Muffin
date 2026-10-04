#!/usr/bin/env bash
# Capture panels_b gallery pages under Xvfb + llvmpipe (one renderer on the VPS at a time: one flock for the whole batch).
# usage: ui/panels_b/shoot.sh [WxH] page [page...]     e.g. ui/panels_b/shoot.sh 1280x800 contracts garden   (no pages = all)
set -euo pipefail
cd "$(dirname "$0")/../.."
RES="1280x800"
if [[ "${1:-}" =~ ^[0-9]+x[0-9]+$ ]]; then RES="$1"; shift; fi
PAGES=("$@")
if [ ${#PAGES[@]} -eq 0 ]; then PAGES=(contracts garden labor skills forge cauldron kiln reforge report shelf salvage vault acre); fi
OUT_DIR="$PWD/shots/panels_b"
mkdir -p "$OUT_DIR"
export RES OUT_DIR
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 bash -c '
  for p in "$@"; do
    xvfb-run -a -s "-screen 0 ${RES}x24" /home/ubuntu/tools/godot/godot --rendering-driver opengl3 --resolution "$RES" --path . res://ui/panels_b/gallery.tscn -- --page="$p" --out="$OUT_DIR/$p.png" ${SHOOT_EXTRA:-} 2>&1 | grep -iE "error|saved|warning: .*script" || true
  done' _ "${PAGES[@]}"
