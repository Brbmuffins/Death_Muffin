#!/usr/bin/env bash
# Puts the xatlas UV packer (MIT; charts.py packs a game model's charts with it, about a quarter more of the texture used than Blender's own packer,
# which stays the fallback) beside Blender, where charts.py finds it: <Blender's folder>/pylib. Run once per Blender install (sessions and the
# Discord agent's sandbox share it; the sandbox only reads it).   bash tools/blender/comfy/setup.sh   (env BLENDER: default /home/ubuntu/tools/blender/blender)
set -euo pipefail
B=${BLENDER:-/home/ubuntu/tools/blender/blender}
B=$(readlink -f "$B")
PY=$(ls "$(dirname "$B")"/*/python/bin/python3.* 2>/dev/null | grep -v config | head -1)
[ -x "$PY" ] || { echo "no Python inside the Blender install beside $B"; exit 1; }
"$PY" -m pip install --quiet --upgrade --target "$(dirname "$B")/pylib" xatlas==0.0.11
"$PY" -c "import sys; sys.path.insert(0, '$(dirname "$B")/pylib'); import xatlas; print('xatlas ready in $(dirname "$B")/pylib')"
