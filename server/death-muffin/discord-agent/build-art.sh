#!/usr/bin/env bash
# The agent's way to turn an approved, generated model into game files (no keys, no network, nothing outside the worktree is writable).
#   build-art.sh <id>      run from the worktree root, after the runner said the generation finished
# Same sandbox as check-godot.sh (sandbox-lib.sh). Inside: tools/build-characters.mjs <id> (Tripo outputs in art-src/tripo/<id>/ -> public/models/...), then the
# result is DEQUANTIZED (Godot's glTF importer rejects KHR_mesh_quantization) and copied into the Godot client:
#   characters/creatures  public/models/<id>/character.glb      -> godot/assets/slice/models/<id>/character.glb
#   props (id prop_<name>) public/models/props/<name>.glb        -> godot/assets/slice/models/props/<name>.glb
# Godot extracts textures and writes .import files the next time it imports the project (check-godot.sh does); commit those next to the model.
set -uo pipefail
ID=${1:-}
[[ "$ID" =~ ^[a-z0-9_]{3,40}$ ]] || { echo "usage: build-art.sh <id>   (id = [a-z0-9_], the one that was generated)"; exit 2; }
TOP=$(git rev-parse --show-toplevel) || exit 2
[ -d "$TOP/art-src/tripo/$ID" ] && [ ! -L "$TOP/art-src/tripo/$ID" ] || { echo "nothing generated for $ID yet (no art-src/tripo/$ID)"; exit 2; }
[ -f "$TOP/tools/build-characters.mjs" ] && [ -d "$TOP/godot" ] || { echo "this worktree has no tools/build-characters.mjs or godot/"; exit 2; }
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export TOP ID
export DM_PAYLOAD='
  set -uo pipefail
  cd "$TOP"
  if ! node tools/build-characters.mjs "$ID" > /tmp/build.log 2>&1; then tail -25 /tmp/build.log; echo "build-characters failed"; exit 1; fi
  tail -5 /tmp/build.log
  case "$ID" in
    prop_*) SRC="public/models/props/${ID#prop_}.glb"; DST="godot/assets/slice/models/props/${ID#prop_}.glb";;
    *)      SRC="public/models/$ID/character.glb";      DST="godot/assets/slice/models/$ID/character.glb";;
  esac
  [ -f "$SRC" ] || { echo "the build did not produce $SRC"; exit 1; }
  mkdir -p "$(dirname "$DST")"
  SRC="$SRC" DST="$DST" node --input-type=module -e "
    import { NodeIO } from \"@gltf-transform/core\";
    import { ALL_EXTENSIONS } from \"@gltf-transform/extensions\";
    import { dequantize } from \"@gltf-transform/functions\";
    const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
    const doc = await io.read(process.env.SRC);
    await doc.transform(dequantize());
    for (const ext of doc.getRoot().listExtensionsUsed()) if (ext.extensionName === \"KHR_mesh_quantization\") ext.dispose();
    await io.write(process.env.DST, doc);
  " || { echo "dequantize failed"; exit 1; }
  ls -l "$SRC" "$DST" | awk "{print \$5, \$9}"
  echo "BUILT: $DST"
'
timeout -k 20 900 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
[ $rc -eq 124 ] || [ $rc -eq 137 ] && echo "build timed out after 15 minutes"
exit $rc
