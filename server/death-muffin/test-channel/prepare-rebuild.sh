#!/usr/bin/env bash
# PREPARE step of a client publish (publish-godot-client.sh with PROJECT=client): makes what git does not hold in the scratch worktree given as $1
# (never the repository): the licensed flipbook sheets first (tools/godot/fx-sheets-sync.sh, from the private folder), so the import takes them in,
# then the game's one setup with the Windows combat core (tools/check/prep.sh --windows: both cores, the import and the crowd's baked models
# (client/crowd/README.md), from the shared cache when nothing they are made of changed). Fails if any of them is missing.
set -euo pipefail
WT="$1"
cd "$WT"
bash tools/godot/fx-sheets-sync.sh "$WT" >/dev/null
bash tools/check/prep.sh --windows "$WT" | tail -1
[ -s client/bin/libdmcore.windows.template_release.x86_64.dll ] || { echo "prepare: the Windows combat core was not built" >&2; exit 1; }
n=$(ls -d client/assets/crowd/baked/*/ 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || { echo "prepare: no crowd model was baked" >&2; exit 1; }
echo "prepared: the combat core (Windows, Linux), the flipbook sheets, imported, $n crowd models baked"
