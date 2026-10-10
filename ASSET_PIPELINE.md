# Asset pipeline

How art, models and audio get into the Godot game. Reuse what exists first (CLAUDE.md); generate only when nothing usable
exists. Every generation step is scripted and resumable, and spend is reported per batch.

```
concept (Gemini)     art-src/concepts/<id>.png       <- art-manifest/gemini-jobs/*.json
  -> 3D + rig (Tripo) art-src/tripo/<id>/*.glb         <- art-manifest/tripo-specs/<id>.json
  -> build            public/models/<id>/character.glb   (props: public/models/props/<id>.glb)
  -> sync into Godot  godot/assets/...                  (tools/godot/sync-*.sh|mjs)
  -> import           godot --headless --path godot --import   (commit the .import files)
```

`art-src/` holds raw outputs and is gitignored. `public/` is the optimized source store. `art-manifest/` is committed and records
prompts, task ids and credits. `godot/assets/` is what the game loads.

## Keys and spend

- Tripo and Gemini keys are in `.ai-keys.local` (gitignored, `TRIPO_API_KEY=`, `GEMINI_API_KEY=`); the tools read them per run and
  never print them. ElevenLabs key: `~/death-muffin/private/elevenlabs-api-key` (outside the repo).
- `node tools/ai/tripo.mjs balance` shows credits (free). Measured Tripo costs: image to model 50 (60 detailed), rig 25,
  retarget 10 per clip; a 7-clip hero is about 155, a static prop about 50. Spend within the owner's current grant.

## Concepts (Gemini)

`node tools/ai/gemini.mjs art-manifest/gemini-jobs/<file>.json [jobId...] [--force]`. Job fields: `id, prompt, out, refs?, crop?,
aspect?, size?, post?`. Existing outputs are skipped unless `--force`. For Tripo input use one character, strict T-pose, empty
hands, plain light-grey background; props one object, three-quarter view. Tintable VFX sprites: glowing white on black with
`post: { lumaAlpha: true }`. Tileable textures: run `node tools/make-seamless.mjs <file>` afterwards.

## Models, rigs, clips (Tripo)

`node tools/ai/tripo.mjs run art-manifest/tripo-specs/<id>.json` is a dry run; add `--yes` to spend. Rules that cost credits when
ignored:
- Always `animationMode: "single"` (batch retargeting bakes all clips into one).
- Bipeds use the biped rig; quadrupeds `rig_type: "quadruped"` (one walk preset). Do not use `rig_type: "avian"` (boned one wing);
  use a biped rig for winged humanoids or no rig for animals.
- Tripo's `hurt` preset is a 14 s lying-injured clip, not a flinch; `tools/build-characters.mjs` keeps it out of play.
- Props: omit `rig` and `animations`. Face budgets: hero 12k, boss 14k, horde enemy 4-5k, props 0.9-3.5k.
- Runs are resumable: task ids are written to `art-src/tripo/<id>/state.json` before polling; failed tasks refund.

## Build

`node tools/build-characters.mjs [id ...]` merges the clip files onto the idle mesh by joint name into one `character.glb`
(dedup, resample, WebP textures 1024/512 px, quantize, prune) plus `clips.json`. Colour variants without new spend:
`node tools/tint-variants.mjs [base]`. Free animation: `node tools/blender.mjs` writes `anim_<name>.glb` from code (gaits,
rig fixes, CC0 retargets); see `docs/BLENDER-PIPELINE.md`.

## Sync into Godot

- UI and ability icons, omens, portraits, status icons: `tools/godot/sync-ui-art.sh`, `tools/godot/sync-game-art.sh`.
- Audio: `tools/godot/sync-audio-assets.sh` (Opus to WAV; Godot cannot import Opus; Vorbis and MP3 are copied as is).
- Models and textures: `tools/godot/sync-slice-assets.mjs` copies the files named in `godot/data/slice/assets_used.json`
  into `godot/assets/slice/` and dequantizes the GLBs (Godot rejects `KHR_mesh_quantization`). See KNOWN-GAPS.md: the exporter
  that wrote `assets_used.json` was removed, so edit that file by hand when you add a model. `tools/godot/fx-sync-models.mjs` does the same for FX models.
- Then `godot --headless --path godot --import` and commit the generated `.import` files. Textures used in 3D (model textures, floors, FX sprites)
  must be VRAM Compressed: set `compress/mode=2` in their `.import` (normal maps `*NormalGL*` also `compress/normal_map=1`) and re-import; a fresh
  import is Lossless, and `npm run hygiene` fails until it is changed (`npm run hygiene -- --fix-textures` does it). UI art stays Lossless.

## Audio generation (ElevenLabs, backup only)

`tools/audio/generate-eleven-music.mjs` and `generate-eleven-ambience.mjs` write private drafts to `~/death-muffin/private/`
(never into the repo); keep only what the owner approves, then run the prepare scripts (`prepare-eleven-*.mjs`) and the sync.

## Verify

After each paid batch run `node tools/ai/validate-animation.mjs art-src/tripo/<id>/anim_*.glb` and `validate-rig.mjs` (see `docs/TRIPO-ANIMATE-IN-PLACE.md`; `animate_in_place` needs no change).
Open the asset in game with `-- --dev-offline --class=2`; the F3 overlay shows frame cost. A PBR Tripo material is mostly
metallic: keep emissive boosts faint (0.15 or less) or models white out under bloom. Run the affected `godot/tests/` suites.
