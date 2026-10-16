#!/usr/bin/env bash
# Bakes the crowd models (client/crowd/README.md) at low priority: tools/bake_crowd.sh [enemy id or model slug ...] (default: the Graves roster: robber, hound,
# penitent, sac, ghoul, rat, the risen's skeleton, and the unrigged moth and bat (their wing beat baked into a loop); the thralls the rites raise:
# the four legions' bodies, the plague bearer's sac and the Bone Colossus).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
# The armed thralls' variants (crowd_looks.json thrall_props): the legions that carry weapons, and the bare skeleton (no legion, archers, bone mages).
[ $# -gt 0 ] || set -- robber hound penitent ghoul rat moth bat skeleton_thrall thrall_legionnaire thrall_sentinel thrall_plague wraith_thrall carrion_sac bone_colossus \
  thrall_legionnaire+warrior thrall_legionnaire+shieldbearer thrall_sentinel+warrior thrall_sentinel+shieldbearer \
  skeleton_thrall+warrior skeleton_thrall+shieldbearer skeleton_thrall+archer skeleton_thrall+bonemage
exec nice -n 10 "$GODOT" --headless --path . --script res://tools/bake_crowd.gd -- "$@"
