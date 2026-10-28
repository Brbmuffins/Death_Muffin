# Asset pipeline

How art, models and audio get into the Godot game. Reuse what exists first (AGENTS.md); generate only when nothing usable
exists. Every generation step is scripted and resumable, and spend is reported per batch.

```
concept (Gemini)     art-src/concepts/<id>.png       <- art-manifest/gemini-jobs/*.json
  -> 3D (ComfyUI)     art-src/comfy/<id>/<label>.glb   <- model-gen.sh on a team PC, then tools/blender/make.mjs ("Image to model")
     or 3D + rig (Tripo, the backup) art-src/tripo/<id>/*.glb <- art-manifest/tripo-specs/<id>.json
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

The backup since DECISIONS B77 (new models come from "Image to model" below): used only when the owner asks for it, within the owner's grant.
`node tools/ai/tripo.mjs run art-manifest/tripo-specs/<id>.json` is a dry run; add `--yes` to spend. Rules that cost credits when
ignored:
- Always `animationMode: "single"` (batch retargeting bakes all clips into one).
- Bipeds use the biped rig; quadrupeds `rig_type: "quadruped"` (one walk preset). Do not use `rig_type: "avian"` (boned one wing);
  use a biped rig for winged humanoids or no rig for animals.
- Tripo's `hurt` preset is a 14 s lying-injured clip, not a flinch; `tools/build-characters.mjs` keeps it out of play.
- Props: omit `rig` and `animations`. Face budgets: hero 12k, boss 14k, horde enemy 4-5k, props 0.9-3.5k, buildings 8k (`BUILDINGS`: the mausoleum). `tools/assets/check-models.mjs`
  (`npm run check:models`: CI over every model, the Discord agent's check over the models a change adds or edits) fails a model over its cap
  (gear 4k, props 6k, buildings 10k, heroes and other characters 20k), with more than one material, gear with a skeleton, or a hero body without the shared biped
  skeleton or its combat clips; over the face budget but under the cap is a warning. Crowd creatures are checked by the crowd bake (5k).
- Combat-trim source clips (`box_03`, `pitch_baseball`, `sing_01`, `basketball_shot`, see `build-characters.mjs` `COMBAT_TRIMS`) need no retarget credits for another biped hero: all Tripo biped rigs share one joint set, so copy the four `anim_*.glb` files from `art-src/tripo/hero_gravecaller/` into the new hero's folder before `build-characters.mjs`; it borrows them from there by itself for `hero_leg_*` bodies and the heroes in `NECRO_HEROES` (include a new playable hero there, or it loses its combat swings).
- Runs are resumable: task ids are written to `art-src/tripo/<id>/state.json` before polling; failed tasks refund.

## Image to model (ComfyUI on a team PC)

How a new model is made (DECISIONS B77; Tripo is the backup): a concept picture made into a model, free, on a team PC's graphics card, by ComfyUI's
"Pixal3D & TRELLIS.2: Image to Model" template run by the team app's `model` job (B76; teamapp/README.md "The model job" for the PC's side), then
finished in Blender here (`tools/blender/make.mjs`, below). In the Tripo bake-off of 2026-10-26 Pixal3D won the brazier and the hound, with its own
paint. It makes **no skeleton**: Blender builds one from the model's shape and makes its clips (B74). The live bone hound was the first (2026-10-27);
the fen spider (eight legs) and the necromancer's scythe followed as tests the same day. The Discord agent asks for three tries of a concept with
`.dm-model-request.json` (server/death-muffin/discord-agent/README.md) and finishes the picked one with `make-model.sh` (its guide: `guides/models.md`).

**The picture** is what Pixal3D builds, so it is a model source, not a painting: "3D modeling source: a game-ready 3D render of ...", one subject whole
and centred on plain flat light grey, even flat light with no shadows or rim light, every part a solid shape big enough to model (no hair, threads, webs
or loose bits), and the dirt and wear painted into the colours (a clean picture gives a toy-like model; the hound's first clean picture did). A creature
stands in a neutral pose with every leg visible, apart and on the ground, seen in three-quarter view from the front and a little above. Good prompts:
`concept_bone_hound_3d_a`, `concept_fen_spider_3d`, `concept_necro_wpn_scythe_3d` in `art-manifest/gemini-jobs/concepts.json`.

`server/death-muffin/model-gen.sh [--pc <name>] [--model pixal3d|trellis2|both] [--faces N] [--texture 1024] [--seeds 0,1] [--set name=value] [--runs runs.json] <out dir> <picture>...`
queues one job (at most 8 runs: every picture with every model and seed, or the runs file's list), waits for it and copies `<label>.glb` and the PC's log
into `<out dir>` (use `art-src/comfy/<id>/`). Make a detailed model (200000 faces, `--set detail=2048 --set grid=1024`, texture 2048, three seeds to pick from: the
settings of every model so far) and bake it down in Blender onto a new mesh at the budget (`finish` below: new UVs, the detailed paint baked onto them).
Never just cut a painted model down: the paint smears. The concept rules are Tripo's (one subject,
plain background; ComfyUI removes the background). A run takes 2 to 10 minutes on a 4070 SUPER. The same picture, model, faces, texture and seed give the
same model again, so a model that goes into the game is recorded as its run (`art-manifest/comfy/<id>.json`: the picture, the run's settings and the
ComfyUI version the log names), with the Blender steps after it and the `game` file they made in `art-src/comfy/<id>/`.

**Shape settings** (team app 0.5.3; `--set name=value` for every run, or a run's `settings`): shape Pixal3D's model before it is cut and painted, rather than fixing it in
Blender afterwards. Each name, its inputs and range are in the workflow's `settings` (`teamapp/comfy/image-to-model.json`; model-gen.sh refuses anything else); the template's
value in brackets. `detail`: the grid the shape is refined to (1536; lower gives fewer fine bits). `grid`: the grid the mesh is rebuilt on before the cut (768; lower is simpler and
rounder). `round`: the rebuild's closing radius in voxels, creases filleted and gaps bridged at that size (1). `sharp`: the rebuild keeps sharp edges and flat faces (false; for props
and buildings). `follow`: how closely the shape stages follow the picture (7.5; lower is looser). `fov` (team app 0.5.4): the camera angle in degrees Pixal3D projects the picture with,
1 to 170 (the template: MoGe's guess from the picture). MoGe's depth detail is not a setting: Pixal3D takes only its angle, not its depth. The rebuild's own smoothing is already at its most.

**Several views** (team app 0.5.5; a run's `views` in the runs file, Pixal3D only): the model is made from more than one picture of the subject. The run's picture is the front; `views` adds
`left` (the subject's left side: its head to the picture's left), `back` and `right` (head to the right), any of them. Every picture goes in as given, so they are made together: square
`.png`s, the subject on black (no background removal here), centred at the same scale in each, the widest spanning about 1/1.1 of the frame (model-gen.sh refuses pictures that are not square
`.png`s). The views come from a turnaround sheet of the concept in its own style (a Gemini job beside the concept's, `concept_<id>_views`), cut into one picture a view; a subject that is
the same on both sides may use its left view mirrored as the right. `fov` is the views' camera angle too (20 unless set; drawn views are close to flat).

## Build

`node tools/build-characters.mjs [id ...]` merges the clip files onto the idle mesh by joint name into one `character.glb`
(dedup, resample, WebP textures 1024/512 px, quantize, prune) plus `clips.json`. A model with a ComfyUI record is built from the record's `game` file
the same way, never from Tripo files; its clips are Blender jobs. Colour variants without new spend:
`node tools/tint-variants.mjs [base]`. Free animation: `node tools/blender.mjs` writes `anim_<name>.glb` from code (gaits,
rig fixes, CC0 retargets); see `docs/BLENDER-PIPELINE.md`. Moves and edits on a model the game already ships (the default over a new Tripo run,
DECISIONS B74) are Blender jobs, `node tools/blender/jobs.mjs run <job.json>` (docs/BLENDER-PIPELINE.md "Jobs"); a rebuild from the Tripo files
loses them until `node tools/blender/jobs.mjs replay <id>` (`build-art.sh` does it).

**From a run to the game file:** `node tools/blender/make.mjs` does the Blender steps the record `art-manifest/comfy/<id>.json` lists on the run's
detailed model and writes the record's `game` file (the Discord agent runs it in its sandbox as `make-model.sh`). `make.mjs fit <id>` finds the game
placement first: `--stand --height <m> --yaw <deg>` for a new subject (stood on the side it rests on), `--ref <old model>` for a remake (fitted onto
the old one; a nearly symmetric shape such as a building can fit back to front, which `--yaw 180` turns round); either way the placed model is written to `work/fit.glb` to look at. The steps (`tools/blender/comfy/kinds.json`, `make.mjs kinds`):
`finish` (the game mesh: a solid rebuild, cut to the budget, new UVs packed by xatlas, the detailed paint, roughness, metal and normals baked on),
`place`, `bend` (a part turned about a joint before the bake: the hound's head), `grime` (dirt painted in) and `rig`, a skeleton built from the
placed model's shape: `quad` is the four-legged one the bone hound has (`Root`, `Hip`, `Spine1-2`, `Chest`, `Neck1-2`, `Head`, `Tail_A-D`,
`FL/FR_Upper/Lower/Paw`, `HL/HR_Thigh/Shin/Meta/Paw`), `legs` any number of legs round one body (the fen spider: `Root`, `Hip`, `Head`, `Abdomen`,
`Abdomen_End`, `L1`-`L4`/`R1`-`R4` `_Upper/_Lower/_Foot`, counted from the front), `biped` the heroes' skeleton on a body in a T or A pose, the
body turned to face +X as every hero body does (refused when its feet then point backwards: the frame's `fit --yaw` is half a turn out). The record keeps the run's settings, so `make.mjs build <id>` remakes the game file from the
same run. A four-legged or many-legged model's moves are one `motion` job on its recipe (`tools/blender/recipes/bone_hound.json`,
`fen_spider.json`); a biped's are one `retarget` job `from` a hero (docs/BLENDER-PIPELINE.md "Biped to biped"). The xatlas packer is set up
once per Blender install (`tools/blender/comfy/setup.sh`). A model placed facing forward this way faces away from the game's camera at no turn,
so its creature row has `"yaw": 3.141592653589793`, as the hounds' do; a biped's row has the heroes' `"yaw": -1.5707963267948966`.

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
  import is Lossless, and `npm run hygiene` fails until it is changed (`npm run hygiene -- --fix-textures` does it; the agent's `build-art.sh` writes
  a model's textures next to it, and a new one's `.import` this way, before Godot first imports them). UI art stays Lossless.

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
