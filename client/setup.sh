#!/usr/bin/env bash
# One-time setup of a checkout or worktree for the rebuilt client: builds the combat core for Linux (if missing) and imports the project.
# The extension is listed in .godot/extension_list.cfg BEFORE the first import: Godot 4.7.2 aborts on exit when it discovers a new
# GDExtension in the middle of a fresh import (seen 2026-10-16), and loads it cleanly when it is listed from the start.
set -euo pipefail
cd "$(dirname "$0")"
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
[ -f bin/libdmcore.linux.template_debug.x86_64.so ] || ../native/build.sh linux
mkdir -p .godot
grep -qx 'res://bin/dmcore.gdextension' .godot/extension_list.cfg 2>/dev/null || echo 'res://bin/dmcore.gdextension' >> .godot/extension_list.cfg
nice -n 10 "$GODOT" --headless --path . --import >/dev/null 2>&1
nice -n 10 "$GODOT" --headless --path . --script res://tests/core_smoke.gd 2>&1 | grep -E '^(PASS|FAIL)'
