#!/usr/bin/env bash
# Bakes the crowd models (client/crowd/README.md) at low priority: tools/bake_crowd.sh [enemy id or model slug ...] (default: the Graves roster's robber and hound).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
[ $# -gt 0 ] || set -- robber hound
exec nice -n 10 "$GODOT" --headless --path . --script res://tools/bake_crowd.gd -- "$@"
