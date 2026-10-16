#!/usr/bin/env bash
# PREPARE step for a test-channel build of the LIVE project (godot/): today's game on Forward+, talking to the test backend.
# Edits only the scratch worktree given as $1 (publish-godot-client.sh's), never the repository. Fails if a line it expects is gone.
set -euo pipefail
WT="$1"
P="$WT/godot/project.godot"
C="$WT/godot/net/dm_config.gd"
swap() {  # file, exact old line, new line
  grep -qxF -- "$2" "$1" || { echo "prepare: expected line not found in $1: $2" >&2; exit 1; }
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
t = open(p).read().split("\n")
open(p, "w").write("\n".join(new if line == old else line for line in t))
PY
}
# Forward+ (DECISIONS B35); its own user:// folder so it never shares the live game's saved login or settings (B38).
swap "$P" 'renderer/rendering_method="gl_compatibility"' 'renderer/rendering_method="forward_plus"'
swap "$P" 'config/name="Death Muffin (Godot slice)"' 'config/name="Death Muffin (test build)"'
# The test backend and the test channel's manifest (online lock, update check).
swap "$C" 'const API_BASE := "https://muffindevelopment.com/death-muffin/api"' 'const API_BASE := "https://muffindevelopment.com/death-muffin/test-api"'
swap "$C" 'const CLIENT_MANIFEST_URL := SITE_BASE + "client/manifest.json"' 'const CLIENT_MANIFEST_URL := SITE_BASE + "client-test/manifest.json"'
echo "prepared: Forward+, user folder \"Death Muffin (test build)\", test backend, client-test manifest"
