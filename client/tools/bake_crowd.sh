#!/usr/bin/env bash
# Bakes the crowd models (client/crowd/README.md) at low priority: tools/bake_crowd.sh [enemy id or model slug ...] (default: the Graves roster: robber, hound,
# penitent, sac, ghoul, rat and the risen's skeleton (the moth and the bat are unrigged models: ROADMAP "Crowd drawing"); the thralls the rites raise:
# the four legions' bodies, the plague bearer's sac and the Bone Colossus).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
[ $# -gt 0 ] || set -- robber hound penitent ghoul rat skeleton_thrall thrall_legionnaire thrall_sentinel thrall_plague carrion_sac bone_colossus
exec nice -n 10 "$GODOT" --headless --path . --script res://tools/bake_crowd.gd -- "$@"
