#!/usr/bin/env bash
# matmap.py with the Python of matmap's home (setup.sh made it), the arguments passed on:
#   bash tools/assets/matmap/run.sh <picture.png> <labels.png> [--overlay <file.jpg>] [--report <file.json>]
set -euo pipefail
MM=${DM_MATMAP_HOME:-$HOME/.cache/dm-ops/matmap}
[ -x "$MM/.venv/bin/python" ] || { echo "no $MM/.venv: run tools/assets/matmap/setup.sh first"; exit 1; }
exec "$MM/.venv/bin/python" "$(dirname "${BASH_SOURCE[0]}")/matmap.py" "$@"
