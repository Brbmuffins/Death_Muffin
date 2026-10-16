#!/usr/bin/env bash
# Setup of a checkout or worktree for the rebuilt client (run it again after switching branches): builds the combat core for Linux and imports.
# The extension is listed in .godot/extension_list.cfg BEFORE the first import: Godot 4.7.2 aborts on exit when it discovers a new
# GDExtension in the middle of a fresh import (seen 2026-10-16), and loads it cleanly when it is listed from the start.
set -euo pipefail
cd "$(dirname "$0")"
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
bash ../native/build.sh linux   # always: scons only recompiles what changed, and a stale library from another branch must not linger
mkdir -p .godot
grep -qx 'res://bin/dmcore.gdextension' .godot/extension_list.cfg 2>/dev/null || echo 'res://bin/dmcore.gdextension' >> .godot/extension_list.cfg
nice -n 10 "$GODOT" --headless --path . --import >/dev/null 2>&1
# A second pass leaves the project clean: on a fresh checkout the first pass loads the project theme (gui/theme/custom) before it has imported
# the theme's fonts and reports errors for them; the second finds nothing to report.
nice -n 10 "$GODOT" --headless --path . --import >/dev/null 2>&1
nice -n 10 "$GODOT" --headless --path . --script res://tests/core_smoke.gd 2>&1 | grep -E '^(PASS|FAIL)'
