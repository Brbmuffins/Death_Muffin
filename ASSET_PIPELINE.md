# Asset pipeline

How art, models and audio get into the Godot game. Reuse what exists first (AGENTS.md); generate only when nothing usable
exists. Every generation step is scripted and resumable, and spend is reported per batch.

```
concept (Gemini)     art-src/concepts/<id>.png       <- art-manifest/gemini-jobs/*.json
  -> 3D + rig (Tripo) art-src/tripo/<id>/*.glb         <- art-manifest/tripo-specs/<id>.json
  -> build            public/models/<id>/character.glb   (props: public/models/props/<id>.glb)
  -> into the game    client/assets/...                 ("Into the game" below)
  -> import           godot --headless --path client --import   (commit the .import files)
```

`art-src/` holds raw outputs and is gitignored. `public/` is the optimized source store. `art-manifest/` is committed and records
prompts, task ids and credits. `client/assets/` is what the game loads.

## Keys and spend

- Tripo and Gemini keys are in `.ai-keys.local` (gitignored, `TRIPO_API_KEY=`, `GEMINI_API_KEY=`); the tools read them per run and
  never print them. ElevenLabs key: `~/death-muffin/private/elevenlabs-api-key` (outside the repo).
- `node tools/ai/tripo.mjs balance` shows credits (free). Measured Tripo costs: image to model 50 (60 detailed), rig 25,
  retarget 10 per clip; a 7-clip hero is about 155, a static prop about 50. Spend within the owner's current grant.

## Concepts (Gemini)

`node tools/ai/gemini.mjs art-manifest/gemini-jobs/<file>.json [jobId...] [--force]`. Job fields: `id, prompt, out, refs?, crop?,
aspect?, size?, post?`. Existing outputs are skipped unless `--force`. For Tripo input use one character, strict T-pose, empty
hands, plain light-grey background; props one object, three-quarter view. Tintable VFX sprites: glowing white on black with
`post: { lumaAlpha: true }`. Flat pictures (icons, portraits, textures) are concepts too and go into the game as "Pictures" below.

## Models, rigs, clips (Tripo)

`node tools/ai/tripo.mjs run art-manifest/tripo-specs/<id>.json` is a dry run; add `--yes` to spend. Rules that cost credits when
ignored:
- Always `animationMode: "single"` (batch retargeting bakes all clips into one).
- Bipeds use the biped rig; quadrupeds `rig_type: "quadruped"` (one walk preset). Do not use `rig_type: "avian"` (boned one wing);
  use a biped rig for winged humanoids or no rig for animals.
- Tripo's `hurt` preset is a 14 s lying-injured clip, not a flinch; `tools/build-characters.mjs` keeps it out of play.
- Props: omit `rig` and `animations`. Face budgets: hero 12k, boss 14k, horde enemy 4-5k, props 0.9-3.5k. `tools/assets/check-models.mjs`
  (`npm run check:models`: CI over every model, the Discord agent's check over the models a change adds or edits) fails a model over its cap
  (gear 4k, props 6k, heroes and other characters 20k), with more than one material, gear with a skeleton, or a hero body without the shared biped
  skeleton or its combat clips; over the face budget but under the cap is a warning. Crowd creatures are checked by the crowd bake (5k).
- Combat-trim source clips (`box_03`, `pitch_baseball`, `sing_01`, `basketball_shot`, see `build-characters.mjs` `COMBAT_TRIMS`) need no retarget credits for another biped hero: all Tripo biped rigs share one joint set, so copy the four `anim_*.glb` files from `art-src/tripo/hero_gravecaller/` into the new hero's folder before `build-characters.mjs`; it borrows them from there by itself for `hero_leg_*` bodies and the heroes in `NECRO_HEROES` (include a new playable hero there, or it loses its combat swings).
- Runs are resumable: task ids are written to `art-src/tripo/<id>/state.json` before polling; failed tasks refund.

## Build

`node tools/build-characters.mjs [id ...]` merges the clip files onto the idle mesh by joint name into one `character.glb`
(dedup, resample, WebP textures 1024/512 px, quantize, prune) plus `clips.json`. Colour variants without new spend:
`node tools/tint-variants.mjs [base]`. Free animation: `node tools/blender.mjs` writes `anim_<name>.glb` from code (gaits,
rig fixes, CC0 retargets); see `docs/BLENDER-PIPELINE.md`.

## Into the game

The game's files are in `client/assets/` (committed; the masters of older art and sound stay in `public/`).
- Models: `server/death-muffin/discord-agent/build-art.sh <id>` (the Discord agent's step, also usable by hand) runs `tools/build-characters.mjs`
  and writes the GLB into `client/assets/slice/models/` dequantized (Godot rejects `KHR_mesh_quantization`). Add a new model's row to
  `client/data/slice/assets_used.json` by hand (KNOWN-GAPS.md: the exporter that wrote it is gone).
- Sounds: `server/death-muffin/discord-agent/build-sound.sh` (below). Older masters in `public/audio/` were converted once (Opus to WAV: Godot
  cannot import Opus); a replacement goes into `client/assets/audio/` the same way.
- Item icons: `tools/generate-armor-assets.mjs` writes the armor sets' icons; every other flat picture comes in through `tools/pictures/build.mjs` ("Pictures").
- Then `godot --headless --path client --import` and commit the generated `.import` files. Textures used in 3D (model textures, floors, FX sprites)
  must be VRAM Compressed: set `compress/mode=2` in their `.import` (normal maps `*NormalGL*` also `compress/normal_map=1`) and re-import; a fresh
  import is Lossless, and `npm run hygiene` fails until it is changed (`npm run hygiene -- --fix-textures` does it). UI art stays Lossless.

## Pictures (icons, portraits, loading art, floor and wall textures)

Every flat picture is one of the kinds in `tools/pictures/kinds.json`: ability, skill, omen, status, item and currency icons, portraits, loading art,
floor and wall textures. A kind holds the folder, the size, a size limit (KB), how Godot imports it (`ui` Lossless, `3d` VRAM Compressed with mipmaps),
whether it tiles, one or two style pictures and a prompt recipe. Each picture has one copy, in that folder; the windows and the HUD read the same file.

```
concept (Gemini)    art-src/concepts/<id>.png     <- art-manifest/gemini-jobs/<id>.json {"kind": ..., "prompt": what to draw}
  -> build          node tools/pictures/build.mjs <kind> <name> <concept id or image path> [--replace]
                    <kind's folder>/<name>.webp + .import + its record in art-manifest/images.json
  -> import         godot --headless --path client --import (completes the .import), then point the game's data at the file
```

- A concept job that names a `kind` gets the kind's recipe and style pictures from the Discord agent's runner, so new pictures match the old ones;
  its prompt says only what to draw. By hand, put the recipe and a style picture in the job yourself. To change a picture, give it as a ref.
- The builder cuts off a light frame the image model drew, crops to the kind's size, makes tiling kinds seamless, lowers the WebP quality until the
  picture fits its limit (it fails rather than ship an oversized file) and records the source, its hash and the concept's prompt.
- A new kind is one entry in `kinds.json` sized like the pictures already in its folder; `node --test tools/pictures/*.test.mjs` (CI) checks the list,
  the builder and that no ability borrows another one's icon. Effect sprites (`client/assets/fx/`) are not a kind yet.
- The Discord agent runs the builder through `server/death-muffin/discord-agent/build-picture.sh` (sandboxed, concept ids only).

## Audio generation (ElevenLabs, backup only)

`tools/audio/generate-eleven-music.mjs` and `generate-eleven-ambience.mjs` write private drafts to `~/death-muffin/private/`
(never into the repo); keep only what the owner approves, then run the prepare scripts (`prepare-eleven-*.mjs`) and the sync.

From Discord, the dev agent asks for a sound effect or track with `audio-manifest/eleven/<id>.json` (the spec, committed); the runner generates it for the
owner's sound users with no budget gate and records the cost (`server/death-muffin/discord-agent/README.md` "New sounds"). Raw takes land in
`audio-src/eleven/<id>/` (gitignored); `build-sound.sh` levels the chosen take (-20 LUFS, peaks at most -1.5 dBTP), installs it as
`client/assets/audio/eleven/<id>.wav` (sfx) or `.mp3` (music) and writes its row in [docs/AUDIO-SOURCES.md](docs/AUDIO-SOURCES.md), the licence record.

## Flipbook sheets (licensed, outside git)

A few VFX sprite sheets come from the owner's licensed pack (`~/vps-handoffs/DeathMuffin/reference/godot_vfx.zip`; godboyhappy ARCLIGHT /
CLEAVE: commercial use, no credit, **not redistributable in a public repository**). Converted greyscale grids live in
`~/death-muffin/private/fx-sheets/` (`<id>.png` + `.png.import`: lossless, mipmaps) and are listed in `fx_data.json` `sheets`;
`tools/godot/fx-sheets-sync.sh` copies them into a checkout (the sheets folder of the game's assets is gitignored). How they are drawn and installed: `client/fx/README.md` "Flipbook sheets". Do not use the pack's
VESPER or REEBOO 3D scenes until their cost is measured: they need Forward+/Mobile or GPUParticles and were ruled out while players ran Compatibility (DECISIONS B12); the game is Forward+ since launch day (KNOWN-GAPS "Assets and effects").

## Verify

After each paid batch run `node tools/ai/validate-animation.mjs art-src/tripo/<id>/anim_*.glb` and `validate-rig.mjs` (see `docs/TRIPO-ANIMATE-IN-PLACE.md`; `animate_in_place` needs no change).
Open the asset in game with `-- --dev-offline --class=2`; the F3 overlay shows frame cost. A PBR Tripo material is mostly
metallic: keep emissive boosts faint (0.15 or less) or models white out under bloom. Run the suites the change can affect (`node tools/rebuild/affected-suites.mjs`; README.md "Tests").
