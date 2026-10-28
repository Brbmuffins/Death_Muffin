# Making new models and armor sets (concepts -> 3D -> renders -> in game)

You cannot call Gemini or the team PCs yourself and you never see a key; the runner generates. Use this only when someone wants a NEW model (a character,
creature, boss, prop, weapon, helm, mantle, or a whole armor set); never for anything an existing model can do. A new move or an edit to a model that
exists (colour, size of a part, a part removed, fewer triangles) is a Blender job (`.dm-guides/blender.md`), free and done here. Read `ASSET_PIPELINE.md`
"Image to model" first. Face budgets: hero 12k, boss 14k, horde enemy 4 to 5k, props 0.9 to 3.5k, buildings (the mausoleum) 8k. `check-godot.sh` refuses a model over its cap (gear 4k,
props 6k, buildings 10k, heroes and characters 20k), with more than one material, or a hero body without the shared biped skeleton and its combat clips
(`tools/assets/check-models.mjs`). A new model is made by Pixal3D on a team PC's graphics card (free) and finished in Blender here (DECISIONS B77).
People see every stage in the thread:

**1. Concepts first.** For each piece write `art-manifest/gemini-jobs/<id>.json` (no `kind`: that is a picture), a list with ONE job:
`[{"id": "concept_<id>", "prompt": "...", "out": "art-src/concepts/<id>.png", "aspect": "1:1"}]` (optional: `refs`, up to 3 images: `art-src/concepts/<name>.png`
or a reference sheet committed at the repo root; `post: {"resize": [w, h], "format": "png"}`). Then write `.dm-concept-request.json` (never commit it):
`{"ids": ["<id>", ...], "note": "one plain sentence"}` (1 to 8 ids), stop, and say in one line what concepts you asked for. The runner makes the images
and posts them numbered in the thread; you hear about them with the next message (Read them before answering). Ask for 2 or 3 variants (separate ids)
when the look is open. To change one, edit its job and request that id again. Always start here unless the requester explicitly skips concepts.
The picture is what Pixal3D builds, so write it as a model source (`art-manifest/gemini-jobs/concepts.json`, `concept_fen_spider_3d` and
`concept_necro_wpn_scythe_3d`, are good prompts to copy): "3D modeling source: a game-ready 3D render of ..."; one subject, whole and centred, on a plain
flat light grey background (#c8c8c8); even flat studio light, no cast shadows, no rim light, no fog; every part a solid shape big enough to model (no hair,
threads, webs, lace or loose bits; fur and bristles painted as colour); the dirt, stains and wear painted into the surface colours (a clean picture gives a
toy-like model). Creatures in a neutral standing pose with every leg visible, apart from the others and flat on the ground, a three-quarter view from the
front and a little above; a prop in a three-quarter view, or upright filling the frame (a weapon). To remake an existing piece, use its old concept as a
`ref` and say "redraw exactly ... as a game-ready 3D render".

**2. 3D tries (free), after people pick.** Write `.dm-model-request.json` (never commit it): `{"ids": ["<id>", ...], "note": "one plain sentence"}` (1 to 4
ids, each one a concept the runner made in this thread; props' ids start with `prop_`; never touch `art-src/concepts/` yourself), stop, and say in one
line what you asked for. The runner makes three tries of each picture on a team PC (about 10 minutes an id) into `art-src/comfy/<id>/` (`bone_hound` gives
`bone-hound-s0.glb`, `-s1`, `-s2`; its message names the files), with each try's run details in `art-src/comfy/<id>/tries.json` (`art-src/` is not committed),
and tells you when they are there. Then run `__TOOLS__/render-model.sh` with that id's three try files (`art-src/comfy/<id>/<file>`; one sheet, the runner posts it), Read
it, say in a line or two which try you would take and why (whole and clean shapes, every leg there, nothing fused or missing, the paint like the picture),
and let people pick. A try came out wrong everywhere: change the concept and ask again.

**3. The game model.** For the picked try write the record `art-manifest/comfy/<id>.json` (`art-manifest/comfy/fen_spider.json` and `prop_necro_wpn_scythe.json`
are examples): `{"id": "<id>", "concept": "concept_<id>", "picture": "art-src/concepts/<id>.png", "run": <the try's entry from tries.json, as it is>,
"steps": [...], "game": "game.glb"}`. `__TOOLS__/make-model.sh kinds` lists the steps and what they take; the usual ones:
- creature: `finish` (`triangles` = its budget, `texture` 512, `metal` none), `place`, `rig` (`body`: `quad` four legs, `legs` a spider's eight or any number
  around one body, `biped` the heroes' skeleton for a two-legged body in a T or A pose with its arms clear of its sides);
- prop or weapon: `finish` (`texture` 512, `metal` mixed when it has iron, `hard: true` for sharp edges), `place`;
- `grime` after `place` when the model came out cleaner than the picture.
Then, one command per call, foreground (each takes the renderer lock; a build takes about 3 minutes):
- `__TOOLS__/make-model.sh fit <id> --stand --height <metres> --yaw <degrees>` for a new subject: it stands the model on its feet and writes the
  record's `frame` and `art-src/comfy/<id>/work/fit.glb`; render that (`render-model.sh art-src/comfy/<id>/work/fit.glb`): the front column must show
  its face. If not, change `--yaw` by what is off (90, 180, ...) and fit again. A remake of a model in the game fits onto the old one instead:
  `--ref client/assets/slice/models/<id>/character.glb` (props: `.../props/<name>.glb`) `--tilt-min 0`. Render the fit beside the old model: a
  nearly symmetric shape (a building) can fit back to front, its door at the other end; fit again with `--yaw 180`.
- `__TOOLS__/make-model.sh build <id>` does the steps into `art-src/comfy/<id>/game.glb` (`--from N` redoes from step N after a change to it);
  `render-model.sh art-src/comfy/<id>/game.glb` to check it.
- `__TOOLS__/build-art.sh <id>` installs it under `client/assets/slice/models/` with its textures; run `__TOOLS__/check-godot.sh --rerun code_load` (Godot
  imports them, with `.import` files next to the model: commit those too). Commit the record, the concept's job file, `art-manifest/images.json` and the model.
  A creature's row faces it the way the hounds' do (`client/data/slice/enemies.json` `models.bone_hound`: `"yaw": 3.141592653589793`).
- A rigged model has no moves yet: they are a `motion` Blender job (`.dm-guides/blender.md`) on a recipe `tools/blender/recipes/<id>.json` (copy
  `bone_hound.json` for four legs, `fen_spider.json` for eight; its bone names are the rig's). A `biped` body takes the heroes' whole move set in
  one step instead: `{"kind": "retarget", "from": "hero_gravecaller"}`. A hero body's row in `client/game/view_models.json` is a copy of
  `hero_gravecaller`'s (the heroes' `"yaw"`) with its slug and url, and the `STRIDE` and `TIMINGS` that job printed.
Then `__TOOLS__/render-model.sh <id> [<id> ...]` (built ids, existing models too, up to 6) for the final sheet. Read it; if a piece came out wrong, say
so plainly. Wire the models into the game only where the request asked.

Tripo (`.dm-art-request.json`, `art-manifest/tripo-specs/`) is the backup: use it only when the owner asks for it in the thread (Tripo spending is paused).

**4. In game.** For gear, take screenshots of a hero wearing it (`.dm-guides/screenshots.md`: `"equip"`, `"view": "hero"`, front and `"turn": 180` for the back; `"discipline"`
for another necromancer) even though screenshots are otherwise only on request, check them, and fix fit or scale before you propose. With a team PC online
write that plan instead of rendering it (`.dm-guides/screenshots.md`): the pictures follow the proposal. Also write a turntable clip of the piece (`.dm-guides/clips.md`, "Model
previews") so the requester sees it turning on a hero in the game's own lighting.

**5. A new armor set, start to finish (you do all of it; nobody else has to step in).** A set someone designs with you (names, bonuses, models) is
not done until it can drop and be worn in the live game. One proposal carries the whole thing; an approver's ✅ ships it, and the ship applies the new
migration to the live database, deploys the backend and publishes the client. The steps:
- *Rules.* A class's own build-defining set is a legendary set: add it to `LEGENDARY_SETS` in `server/rules/content/legendarySets.ts` (`disciplineId`,
  `name`, `wearer`, `color`/`accent`, two `stats` from the class's weapon, `lore`, five piece names); its item ids are `leg_<setId>_<part>` and it drops
  from area bosses like the others (70% to its own class). Class and ascended sets are `ARMOR_SETS` / `ASCENDED_ARMOR_SETS` in `armorSets.ts`.
- *Bonuses.* Add the set to `client/data/content/setBonuses.json` `SET_BONUSES` (tiers 2, 4, 5): an effect the set totals fold (see existing sets and
  `client/rules/gear/dm_set_text.gd` for the keys and their words), or `{"text": "..."}` for a bonus coded elsewhere (as `client/rules/combat/dm_reaper_set.gd` does).
- *Everything else follows from those two:* run `__TOOLS__/regen-godot.sh` (it refreshes every client data copy, the content manifest and the inventory
  icons, writes the new `server/death-muffin/backend/migrations/NNN-armor-<set>.sql` with the item rows, rebuilds the server rules and remakes the loot
  rules' recorded answers the new set moves), then `__TOOLS__/check-godot.sh --rerun code_load` so Godot imports the new icons. Commit all of it, including
  the new `.sql`, the icons, the `.import` files and the rewritten fixtures in `client/tests/rules_loot/fixtures`.
- *Look* (`client/data/slice/necro_gear.json`, read by `client/game/dm_gear_models.gd` and `client/game/dm_avatar.gd`): `mantle_by_set_id.<setId>` (worn chest
  piece shows it), `helm_by_tier.<setId>` (its head piece shows its own helm), `weapon_by_set_id.<setId>` `{kind, prop, pieces}` (weapons of that kind show
  the set's prop from that many pieces; the Reaper's scythe), `legendary_hero_by_set_id` (a whole rigged body at 3+ pieces; the Reaper takes only her own
  set's; `covers_props: true` when the body already wears the set's hood/mantle). Add new models to `client/data/slice/assets_used.json`.
- *A legendary set NEEDS its own full body* to look right: props alone (helm + mantle on the class body) read as a pile of armor. Ask for one rigged
  character in the same concept round as the props: a full-body T-pose concept of a hero wearing the whole set, id `hero_leg_<setId>`. Make it as in
  steps 2 and 3 (`finish` with `triangles` 12000, `texture` 1024 and `metal` as for a creature, `place`, `rig` `biped`; `fit --stand --height
  1.88`), then give it the moves with the Blender job `{"kind": "retarget", "from": "hero_gravecaller"}` (every clip the class's rites play;
  `"from": "hero_reaper_v2a"` for a Reaper set). Cloth hanging below the knee (a long robe or skirt) stretches between the legs on a stride: ask
  for a concept whose robe stops at the knee or is split, or say in the proposal that it will stretch. Add its row to `client/game/view_models.json`
  (step 3's hero row; copy `hero_reaper`'s for a Reaper set) and to `legendary_hero_by_set_id`. Then the in-game screenshots of step 4, front and
  back, at 3+ pieces. Tripo (`art-manifest/tripo-specs/hero_leg_plague_choir.json`) only when the owner asks for it.
- *Decisions.* When the requester has not said where it drops or how strong it is, do not stop to ask: use the defaults above (legendary, boss drops,
  legendary stats) and state them in the proposal so they can change them in the next round. Ask only when the request contradicts itself.
Never edit `tools/ai/`.

**The game's side:** how the client takes in models is `client/tools/ASSETS.md`, and the look of creatures and worn gear is `client/game/README.md`. In a workspace made before 2026-10-21 `client/tools/ASSETS.md` is not there yet: read only the "Assets" section of `client/README.md` instead.
