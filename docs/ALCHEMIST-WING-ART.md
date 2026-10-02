# Alchemist's Wing art (2026-10-02)

Props and three guide NPCs for the Alchemist's Wing / Chapterhouse. Pipeline: Gemini concept -> Tripo P1 (standard
texture) -> `tools/build-characters.mjs`. Specs: `art-manifest/tripo-specs/{prop_alch_*,npc_*}.json`; task ids and
credits per asset: `art-manifest/tripo/<id>.json`; concept jobs: `art-manifest/gemini-jobs/alchemist-wing-v{1,2}.json`;
extra clip jobs: `art-manifest/alchemist-anim-jobs.json`. The room layout is NOT built.

Screenshots (three.js viewer, `node tools/qa/model-sheet.cjs`, not the live game camera):
`docs/screenshots/alchemist-wing/props/sheet.png`, `.../npcs/sheet.png` (rows = Prior, Sexton, Apothecary; columns = idle, talk
mid-gesture, talk late; Prior's third column is `talk2`), plus one PNG per asset in the same folders.

## Props (`public/models/props/<id>.glb`, load with `PROP_URL(id)`)

Heights are suggested world heights (the GLBs are unit-agnostic; scale to the target). Footprints are at that height (x, z).

| id | suggested height | footprint | tris | placement note |
|---|---|---|---|---|
| `alch_cauldron` | 1.3 | 1.2 x 1.4 | 3051 | room centrepiece; embers glow underneath, pair with a green/violet light |
| `alch_alembic` | 1.8 | 1.3 x 1.1 | 2926 | against a wall; the glass collecting flask from the concept did not survive (see rejected) |
| `alch_reagent_shelf` | 2.0 | 0.8 x 1.8 | 2710 | wall-backed; check facing in the room and rotate |
| `alch_drying_rack` | 2.0 | 1.0 x 1.85 | 2467 | free-standing or against a wall; dark, give it light |
| `alch_mortar_table` | 1.0 | 0.7 x 0.9 | 2342 | player-facing crafting table, a good interaction anchor |
| `alch_bubbling_vat` | 1.1 | 1.2 x 1.25 | 2064 | step-ladder on one side, paddle on the other; keep that side clear |
| `alch_counter` | 1.2 | 1.65 x 2.4 | 2534 | the counter and the back drawer rail are one mesh with a visible gap between them; the NPC stands in the gap |
| `alch_bone_candles` | 1.0 | 0.6 x 0.6 | 2419 | has faint violet glow baked in; add flame sprites/lights in code |
| `alch_canopic_jars` | 0.8 | 0.45 x 1.0 | 1977 | three opaque ceramic jars on a plinth; shelf-top or counter dressing |
| `alch_herb_bundle` | 0.9 | 0.6 x 0.65 | 1508 | hang from the rope loop at the top (origin at the bottom, so lift by its height) |
| `alch_station_sign` | 2.4 | 0.65 x 1.4 | 2274 | marks the brewing station; has a green lantern hook (add a light) |
| `alch_totem_stirrer` | 1.2 | 1.0 x 1.35 | 1528 | sigil stone with a violet reagent bowl; good at room entrance |

All use 512 px WebP textures (4.7 MB for everything below, 0.1-0.2 MB per prop). Bone-candle/vat/cauldron have painted-in
glow; if bloom whites them out, lower exposure, do not add emissive (>0.15) per ASSET_PIPELINE.

## NPCs (`public/models/npc_*/character.glb`, registered in `CREATURE_MODELS`)

| slug | height | tris | clips | notes |
|---|---|---|---|---|
| `npc_prior` | 1.8 | 7866 | idle 15.37 s, walk 2.37 s, talk 4.03 s, talk2 3.53 s | elderly Covenant priest, bone rosary, black-bell stole |
| `npc_sexton` | 1.8 | 7870 | idle, walk, talk | gravedigger; lantern and key ring are baked into the mesh. **No spade**: the concept was empty-handed for the T-pose; attach a spade prop to the hand bone with `Creature.attach` (there is no spade GLB yet) |
| `npc_apothecary` | 1.75 | 7772 | idle, walk, talk | goggles/cap/leather apron/vial bandolier; deliberately not a plague doctor |

Like every Tripo character here, the model faces +X in its own frame; the game's `Creature` already turns it to +Z forward.
`talk` is the Tripo `agree` preset (calm open-hand explaining gesture, in place). `talk2` (Prior only) is `angry_01` (emphatic
sermon gesture, hands rise above head). `'talk'` was added to `CreatureAnim` in `src/graphics/Creature.ts` with fallback to `idle`;
nothing plays it yet. idle and walk have root drift (walk travels ~1.5 m per loop in the raw clip): use `inPlace: true` as the
hero avatars do (`Avatars.ts`).

### Clip measurements (`tools/measure-clips.mjs`, hip fraction of standing height)

| clip | dur | hip min | travel | peak hand | verdict |
|---|---|---|---|---|---|
| idle | 15.37 s | 0.99 | 0.17 m | 0.12 m/s | kept |
| walk | 2.37 s | 0.97 | 1.5-1.6 m | 1.2-1.3 m/s | kept (use inPlace) |
| talk (agree) | 4.03 s | 1.00 | 0.03 m | 0.9-1.1 m/s | kept |
| talk2 (angry_01, Prior) | 3.53 s | 0.85 | 0.11 m | 5.2 m/s | kept for Prior only |

## Credits

Balance 4985 -> 3960 = **1025** credits (cap 1150).

- 12 props at 50 = 600 (the per-asset "spent" lines in the run logs overlap because the NPC batch ran in parallel; the balance difference is authoritative)
- 3 characters at 50 + rig 25 + idle/walk/cast_a_spell 30 = 105 each = 315
- extra clips: Prior `angry_01`, `greet_01`, `greet_02`, `agree`; Sexton and Apothecary `agree` = 60
- canopic jars replacement prop = 50

## Rejected / not shipped

- `cast_a_spell` as the NPC gesture: measured fine (hip 0.92) but it is a lunging cast pose; built into the GLB first, then removed (kept in `art-src/tripo/<id>/rejected/`). 30 credits.
- `greet_02` (hand-to-forehead salute) and `greet_01` (walks 2.3 m): not used, 20 credits.
- `alch_specimen_jars`: Tripo turned the transparent glass jars into opaque grey cylinders, the specimens inside vanished. Built, looked at, deleted from `public/`; replaced by `alch_canopic_jars` (opaque ceramic jars, which read well). Manifests are kept. 50 credits.
- Known compromises kept: alembic lost its glass flask; counter has a gap between counter and rail; drying rack herbs are low contrast.

## Tooling added

`tools/qa/model-sheet.cjs` + `tools/qa/viewer/model-viewer.html` (render GLBs, optionally at a clip time, to PNG and a contact sheet; needs
playwright-core via `DM_PLAYWRIGHT_MODULE`), `RETARGET_LOG`/`RETARGET_BUDGET` env overrides in `tools/ai/retarget-clips.mjs`,
`agree`/`angry_01` clip names in `tools/build-characters.mjs`.

## Dressing pass (2026-10-02, branch `dm/wing-dressing`)

No new generation (0 Tripo credits). The room is dressed from `WING_PROPS` in `src/content/layout.ts` (~65 placements: all 12 `alch_*`
props in multiples plus `workbench`, `candles`, `bone_pile`, `coffin_stack`, `covenant_lectern`, `grave_lantern`; optional `s` scale,
`tilt`, `y`), `WING_FLOOR` (three rugs and four spills, drawn by `WorldView.buildWingFloor`), warm `wing_floor.webp` / `wing_wall.webp`
(`node tools/make-wing-textures.mjs`, derived from the purple flagstone and wall), and `PROP_LIFT` in `WorldView.ts` (brightened private
materials for the herb bundles and drying rack). Lights come from the props' existing `light` specs (candle benches, lanterns, vats,
cauldron); the 5-point-light pool is unchanged. The Sexton carries `tool_spade` via `NPC_LOOKS.sexton.held` (`NpcViews.load`).
Screenshots: `docs/screenshots/alchemist-wing/dressing/` (before-* / after-*). Low-quality perf (smoke, wide view): Chapterhouse 125 calls /
356k tris, Wing 140 / 394k (+12% / +10.6%); before the pass the Wing was 100 / 315k against a 122 / 335k Chapterhouse.
