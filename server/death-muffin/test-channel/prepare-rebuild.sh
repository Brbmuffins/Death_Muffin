#!/usr/bin/env bash
# PREPARE step for a test-channel build of the rebuilt client (client/, DECISIONS B41), run by publish-godot-client.sh with PROJECT=client.
# Makes what git does not hold, in the scratch worktree given as $1 (never the repository): the combat core for Windows (the export) and
# Linux (the headless import and bake load it), the licensed flipbook sheets (tools/godot/fx-sheets-sync.sh, from the private folder), an import, and the crowd's baked models (client/assets/crowd/baked, client/crowd/README.md). Fails if any of them is missing.
set -euo pipefail
WT="$1"
cd "$WT"
bash native/build.sh >/dev/null
bash tools/godot/fx-sheets-sync.sh "$WT" >/dev/null
bash client/setup.sh >/dev/null
bash client/tools/bake_crowd.sh >/dev/null
[ -s client/bin/libdmcore.windows.template_release.x86_64.dll ] || { echo "prepare: the Windows combat core was not built" >&2; exit 1; }
n=$(ls -d client/assets/crowd/baked/*/ 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || { echo "prepare: no crowd model was baked" >&2; exit 1; }
echo "prepared: the combat core (Windows, Linux), the flipbook sheets, imported, $n crowd models baked"
