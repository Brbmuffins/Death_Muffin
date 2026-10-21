# Making new models and armor sets (concepts -> 3D -> renders -> in game)

You cannot call Gemini or Tripo yourself and you never see their keys; the runner generates. Use this only when someone wants a NEW model (a character,
creature, boss, prop, weapon, helm, mantle, or a whole armor set); never for anything an existing model can do. Read `ASSET_PIPELINE.md` first (concept
rules: one subject, strict T-pose and empty hands for characters, three-quarter view for props, plain light grey background, flat lighting; face
budgets: hero 12k, boss 14k, horde enemy 4 to 5k, props 0.9 to 3.5k). `check-godot.sh` refuses a model over its cap (gear 4k, props 6k, heroes and
characters 20k), with more than one material, or a hero body without the shared biped skeleton and its combat clips (`tools/assets/check-models.mjs`).
People see every stage in the thread, the way the necromancer gear was made:

**1. Concepts first (no model credits).** For each piece write `art-manifest/gemini-jobs/<id>.json` (no `kind`: that is a picture), a list with ONE job:
`[{"id": "concept_<id>", "prompt": "...", "out": "art-src/concepts/<id>.png", "aspect": "3:4"}]` (optional: `refs`, up to 3 images: `art-src/concepts/<name>.png`
or a reference sheet committed at the repo root; `post: {"resize": [w, h], "format": "png"}`). Then write `.dm-concept-request.json` (never commit it):
`{"ids": ["<id>", ...], "note": "one plain sentence"}` (1 to 8 ids), stop, and say in one line what concepts you asked for. The runner makes the images
and posts them numbered in the thread; you hear about them with the next message (Read them before answering). Ask for 2 or 3 variants (separate ids)
when the look is open. To change one, edit its job and request that id again. Always start here unless the requester explicitly skips concepts.

**2. 3D, after people pick.** For each chosen piece write `art-manifest/tripo-specs/<id>.json`: `{"id": "<id>", "input": "art-src/concepts/<id>.png",
"generation": {"model": "P1-20260311", "face_limit": 7000, "texture_quality": "detailed"}, "rig": {"model": "v1.0-20240301", "rig_type": "biped"},
"animations": ["preset:biped:idle", "preset:biped:walk"], "animationMode": "single"}`. `rig_type: "quadruped"` uses model `v2.5-20260210` and only
`preset:quadruped:walk`. Props (weapons, helms, mantles) have no `rig` and no `animations`, and their id starts with `prop_`. `<id>` is lower-case letters, digits
and underscores (3 to 40) and must not be an existing model. `face_limit` 300 to 14000, `texture_quality` `standard` or `detailed`, at most 10 animations, biped
presets only from the pipeline doc (idle, walk, run, slash, cast_a_spell, hurt, fall, dig, dive, hit_to_body_01, hit_to_head, defeat_03, front_kick_01, ...).
No other fields are accepted. Then write `.dm-art-request.json` (never commit it): `{"ids": ["<id>", ...], "note": "one plain sentence"}` (1 to 6 ids; a
whole set goes in one request). The concept images people saw are reused as they are: never touch `art-src/concepts/` yourself.
Ask for as little as does the job: a prop costs about 60 credits, a rigged and animated character 150 to 285 (60 for the model, 25 for the rig, 10 per
animation). The runner posts the concepts, what will be generated and the estimated credits with the requester's remaining budget and the live Tripo
balance, and waits for an approver's ✅. End your reply with one line saying what you asked for and that it is waiting for approval; do not start the other work yet.

**3. Build, render, fit.** After the generation the runner tells you the files are ready. For each id (one command per call, foreground): `__TOOLS__/build-art.sh <id>`,
then commit the two spec files, `art-manifest/tripo/<id>.json`, `art-manifest/images.json` and the GLB it installs under `client/assets/slice/models/`; run
`__TOOLS__/check-godot.sh --rerun code_load` (Godot's import adds `.import` files and textures next to the model: commit those too). Then `__TOOLS__/render-model.sh <id> [<id> ...]`
(1 to 6 ids, existing models too; about 20 s per model): it writes one sheet `.dm-shots/models-<first id>.png` with front, side and back of each model, which the
runner posts after your turn. Read it; if a piece came out wrong, say so plainly. Wire the models into the game only where the request asked.

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
  character in the same concept round as the props: a full-body T-pose concept of a hero wearing the whole set (`"rig": {"model": "v1.0-20240301",
  "rig_type": "biped"}`, the same ten animations as `art-manifest/tripo-specs/hero_leg_plague_choir.json`, about 185 credits), id `hero_leg_<setId>`. After the
  build (`build-art.sh` gives every `hero_leg_*` body the combat clips the class's rites play), add its row to `client/game/view_models.json` (copy
  `hero_leg_plague_choir`'s, or `hero_reaper`'s for a Reaper set, with the new slug and url) and to `legendary_hero_by_set_id`. Then the in-game screenshots
  of step 4, front and back, at 3+ pieces.
- *Decisions.* When the requester has not said where it drops or how strong it is, do not stop to ask: use the defaults above (legendary, boss drops,
  legendary stats) and state them in the proposal so they can change them in the next round. Ask only when the request contradicts itself.
Never edit `tools/ai/`.
