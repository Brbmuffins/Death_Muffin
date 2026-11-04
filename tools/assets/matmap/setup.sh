#!/usr/bin/env bash
# Gets matmap.py ready: a Python 3.10 venv with the packages of requirements.txt (CPU torch, from PyTorch's CPU index) and the three pinned models
# (SAM 2.1, SigLIP 2, YuNet) in the model cache. Both live in matmap's home, ~/.cache/dm-ops/matmap or the env DM_MATMAP_HOME, so sessions and the
# Discord agent's sandbox share them. Safe to run again: what is there is only checked.   bash tools/assets/matmap/setup.sh
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MM=${DM_MATMAP_HOME:-$HOME/.cache/dm-ops/matmap}
export DM_MATMAP_HOME=$MM
PY=$MM/.venv/bin/python
mkdir -p "$MM"
if [ ! -x "$PY" ]; then
  command -v python3.10 >/dev/null || { echo "python3.10 is missing (the venv is built with it)"; exit 1; }
  python3.10 -m venv "$MM/.venv"
  echo "made $MM/.venv"
fi
nice -n 15 "$PY" -m pip install --quiet --disable-pip-version-check -r "$HERE/requirements.txt"
# the models, by the commits matmap.py names, into HF_HOME (default <home>/hf, which matmap.py sets)
PYTHONPATH=$HERE nice -n 15 "$PY" - <<'PYEOF'
import os, matmap
print("matmap home: ", matmap.HOME)
print("python:      ", matmap.HOME + "/.venv/bin/python")
print("model cache: ", os.environ["HF_HOME"])
for name, path in matmap.fetch_models().items():
    print(f"model {name:7}", path)
PYEOF
echo "ready: bash $HERE/run.sh <picture.png> <labels.png> [--overlay <file.jpg>] [--report <file.json>]"
