#!/usr/bin/env bash
# The agent's way to turn an approved, generated model into game files (no keys, no network, nothing outside the worktree is writable).
#   build-art.sh <id>      run from the worktree root, after the runner said the generation finished (a ComfyUI model: after make-model.sh build <id>)
# Same sandbox as check-godot.sh (sandbox-lib.sh). Inside: tools/build-characters.mjs <id> (Tripo outputs in art-src/tripo/<id>/, or for a model made from a
# ComfyUI run, art-manifest/comfy/<id>.json, its game file in art-src/comfy/<id>/ -> public/models/...), then the
# result is DEQUANTIZED (Godot's glTF importer rejects KHR_mesh_quantization) and copied into the Godot client:
#   characters/creatures  public/models/<id>/character.glb      -> client/assets/slice/models/<id>/character.glb
#   props (id prop_<name>) public/models/props/<name>.glb        -> client/assets/slice/models/props/<name>.glb
# A model with Blender jobs on record (art-manifest/blender/<id>.json, blender-job.sh) gets them done again on the rebuilt file (tools/blender/jobs.mjs replay).
# The model's textures are written next to it here (<model>_<texture name>.webp, the bytes Godot's extraction would write), and a texture
# with no .import yet gets one, VRAM compressed (a normal map as one), as the repo hygiene check wants; Godot imports them the next time it
# imports the project (check-godot.sh does). Commit them and their .import files next to the model. Godot does not extract them itself:
# it leaves an image alone whose .import it did not write, so a new model's textures never appeared and a rebuilt one's stayed old.
set -uo pipefail
ID=${1:-}
[[ "$ID" =~ ^[a-z0-9_]{3,40}$ ]] || { echo "usage: build-art.sh <id>   (id = [a-z0-9_], the one that was generated)"; exit 2; }
TOP=$(git rev-parse --show-toplevel) || exit 2
RAW="$TOP/art-src/tripo/$ID"; [ -f "$TOP/art-manifest/comfy/$ID.json" ] && RAW="$TOP/art-src/comfy/$ID"
[ -d "$RAW" ] && [ ! -L "$RAW" ] || { echo "nothing generated for $ID yet (no ${RAW#"$TOP"/})"; exit 2; }
if [ "$RAW" = "$TOP/art-src/comfy/$ID" ]; then   # a ComfyUI model: its game file comes from make-model.sh build, after the record's last change
  GAME="$RAW/$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["game"])' "$TOP/art-manifest/comfy/$ID.json" 2>/dev/null)"
  [ -f "$GAME" ] && [ "$GAME" -nt "$TOP/art-manifest/comfy/$ID.json" ] || { echo "the game file of $ID is missing or older than its record: run make-model.sh build $ID first"; exit 2; }
fi
[ -f "$TOP/tools/build-characters.mjs" ] && [ -d "$TOP/client" ] || { echo "this worktree has no tools/build-characters.mjs or client/"; exit 2; }
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
# Combat-trim source clips for a hero (build-characters.mjs COMBAT_TRIMS): the shared checkout's raw hero_gravecaller run, read-only in the sandbox.
DM_TRIM_SOURCE="$(dirname "$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir)")/art-src/tripo/hero_gravecaller"
export TOP ID DM_TRIM_SOURCE
export DM_PAYLOAD='
  set -uo pipefail
  cd "$TOP"
  if ! node tools/build-characters.mjs "$ID" > /tmp/build.log 2>&1; then tail -25 /tmp/build.log; echo "build-characters failed"; exit 1; fi
  tail -5 /tmp/build.log
  case "$ID" in
    prop_*) SRC="public/models/props/${ID#prop_}.glb"; DST="client/assets/slice/models/props/${ID#prop_}.glb";;
    *)      SRC="public/models/$ID/character.glb";      DST="client/assets/slice/models/$ID/character.glb";;
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
  if [ -f "art-manifest/blender/$ID.json" ]; then
    HOME=$(mktemp -d /tmp/dmblender-home.XXXXXX) nice -n 10 node tools/blender/jobs.mjs replay "$ID" || { echo "replaying the Blender jobs of $ID failed"; exit 1; }
  fi
  DST="$DST" node --input-type=module -e "
    import { NodeIO } from \"@gltf-transform/core\";
    import { ALL_EXTENSIONS } from \"@gltf-transform/extensions\";
    import { existsSync, writeFileSync } from \"node:fs\";
    const doc = await new NodeIO().registerExtensions(ALL_EXTENSIONS).read(process.env.DST);
    const normals = new Set(doc.getRoot().listMaterials().map((m) => m.getNormalTexture()).filter(Boolean));
    const EXT = { \"image/webp\": \"webp\", \"image/png\": \"png\", \"image/jpeg\": \"jpg\" };
    for (const t of doc.getRoot().listTextures()) {
      if (!t.getName() || !EXT[t.getMimeType()]) continue;
      const f = process.env.DST.slice(0, -4) + \"_\" + t.getName() + \".\" + EXT[t.getMimeType()];
      const n = normals.has(t);
      writeFileSync(f, t.getImage());
      if (!existsSync(f + \".import\")) writeFileSync(f + \".import\", [\"[remap]\", \"\", \"importer=\\\"texture\\\"\", \"type=\\\"CompressedTexture2D\\\"\", \"\", \"[params]\", \"\",
        \"compress/mode=2\", \"compress/high_quality=\" + !n, \"compress/normal_map=\" + (n ? 1 : 0), \"mipmaps/generate=true\", \"detect_3d/compress_to=1\", \"\"].join(\"\\n\"));
    }
  " || { echo "writing the textures failed"; exit 1; }
  ls -l "$SRC" "$DST" | awk "{print \$5, \$9}"
  echo "BUILT: $DST"
'
timeout -k 20 900 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
[ $rc -eq 124 ] || [ $rc -eq 137 ] && echo "build timed out after 15 minutes"
exit $rc
