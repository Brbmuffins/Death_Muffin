# godot/game: shared in-world classes

Shared classes that `DmNextGame` (`godot/next/`) and the UI use. Some file headers still say "DmGame" or cite `WorldScene.ts`; the root is `DmNextGame`.

| group | files |
|---|---|
| Views | `dm_creature*.gd`, `dm_avatar.gd`, `dm_entity_views.gd`, `dm_boss_view.gd`, `dm_pet_view.gd`, `dm_npc_views.gd`, `dm_node_views.gd`, `dm_laborer_views.gd`, `dm_gear_props.gd`. Model rows come from `view_models.json` |
| Player | `dm_loadout.gd`, `dm_inventory.gd`, `dm_progress_sync.gd` (debounced saves to the backend) |
| Combat helpers | `dm_auto_combat.gd`, `dm_auto_dodge.gd`, `dm_boss_telegraphs.gd`, `dm_fdlibm_x.gd`, `dm_hitstop.gd`, `dm_rite_fx.gd` |
| Leftovers | `dm_game_hud.gd`: only the static `DmGameHud.art(path)` icon helper is used (the HUD view-model is `DmNextHudVm`, shape in `ui/hud/README.md`). `dm_game_rewards.gd` and `dm_player.gd` are not called by the live game (`tests/rewards` uses them); live rewards are `next/rewards/` |
| Gathering / labor | `dm_gather_loop.gd`, `dm_gather_session.gd`, `dm_skills.gd`, `dm_game_labor.gd` |
| Settings / perf | `dm_settings.gd`, `dm_graphics_preset.gd`, `dm_resolution_governor.gd`, `dm_caster_budget.gd`, `dm_warmup.gd` |
| Offline | `dm_offline.gd`: mock backend with the item catalogue, used by `-- --dev-offline` and by tests |

`dm_event_fx.gd` and `dm_event_fx_{boss,telegraph,zones}.gd` (`DmEventFx`) are the event-to-VFX/audio router, written for the old DmGame host.
Only the enemy-fx subset is reachable: `next/enemy_fx/dm_enemy_fx.gd` creates one with a reduced host (`dm_enemy_fx_host.gd`) for enemy telegraphs, deaths and voices; the sim-record, mirror and ability code paths are dead.

## Creature rendering
`DmCreatureMat` is the one creature shader. Models in `CULL_BACK_SLUGS` (closed glTF bodies: under 2% open edges, winding agrees with the normals) render back-face culled;
every other model, and every winged or spectral body, stays `cull_disabled` (hair cards, cloaks, open robes, thin cloth). Add a slug only after checking its mesh is closed.
Only the nearest enemies cast into the moon shadow (`DmCasterBudget`, counts per preset in `DmGraphicsPreset`, polled at 2 Hz by `DmNextPerf`); the hero, thralls and bosses always cast.
The boss light and the shared Binbun flash light are `visible = false` while their energy is zero.

## Creature animation (`dm_creature.gd`)
The AnimationPlayer is advanced by hand (`update(dt)`: animation LOD, hitstop). Blends: swing in over 0.3 x its wind-up (0.06-0.14 s), flinch 0.09, death 0.12, back to the loop 0.2, idle/walk/run 0.28.
Walk and run are stride-matched (`set_ground_speed`, allocation-free plan). Idle starts at a random phase and +-8% rate per non-hero body so a crowd does not breathe in step.
A procedural layer rides the single model node (no skeleton work, `_fx_step` runs only while one is active, `busy()` keeps it at full rate): hit recoil (`react`, fired by a fresh `set_flash(1)`
and by `flinch`), strike lunge timed to the clip's impact (`play_strike`; the hounds, which have no attack clip, lunge and bite with the body alone), `topple` for rigs with no death clip
(eased 0.45 s, then the pose freezes), `set_rise` (enemy and thrall spawn climb). Boss swings use `play_strike` so a 6.6 s clip never plays out its tail. Tests: `tests/game/anim_run.gd`.

## Held props and gear look (`dm_creature.gd`, `dm_gear_props.gd`, `dm_gear_models.gd`, `dm_gear_fx.gd`, `dm_avatar.gd`)
- **Held props** (`DmCreature.attach_held(bone, prop, spec)`; the hero's staff, worn weapons and off-hands): the prop's origin (its grip point, moved `hold` metres up its +Y)
  sits on the palm centre measured once per rig from the skinned hand vertices (`palm_of`; the rigs have no finger bones), its +Y along the knuckle line (hand-local X, mirrored for the
  left hand) leaned `lean` degrees toward the fingers and rolled `roll` about itself. It is a rigid child of the bone attachment, so it follows the hand exactly with no script per frame (the older `attach(bone, obj, dir, follow)` with its
  world-up lock and calibration is only for thralls, enemies and tools). `DmGearProps.HOLDS` is the per-kind table (staff, scythe, wand, sickle, skull_focus, mourning_bell, grimoire/tome, sword, dagger, mace,
  bow, shield, default_staff); a model made later needs a row there (or gets `HOLD_DEFAULT`) and a grip at its origin with its long axis +Y. Tuning a kind: render it (idle, run, cast) and adjust lean / roll / hold.
- **Real gear models** (`DmGearModels`, table `godot/data/slice/necro_gear.json`; props are `models/props/necro_*.glb`, one mesh, one material, one draw call each):
  - *Weapons*: the seven necromancer kinds (and the default staff, in the bone tier with the discipline's soul-light) are the real models, scaled to the table's `length_m` and seated so the shaft at `grip_t` (measured from the model's vertices at that height, `shaft_at`: a scythe's
    shaft is not the middle of its bounds) is at the origin; a `tip` meta node marks the top end (the spell origin). The metal tiers (bone, iron, gold, hell, moon) are one model each in a subtle tint (within 0.85-1.1 per channel, the model's texture stays) and a low emission accent (`TIER_DRESS`, k <= 0.4, following the
    texture's bright detail), one shared material per (model, tier). The Reaper keeps her own scythe.
  - *Helm*: the head slot shows the tier helm model (`helm_tier_of`: set heads by collection, class sets iron, ascended silver, legendary hellsteel; `helm_copper` / `helm_iron` copper / iron, `helm_gold` silver), over the rig's own hood (the hood stays; the head region also keeps its faint trim tint). Hide helms hides the model.
    The model is 1.5x the measured head height (`HELM_FIT`) and sits 0.03 m above the head's top (`HELM_OVER`).
  - *Mantle*: a chest piece of a class set or its ascended set shows that set's mantle on the upper body, 1.65x the measured chest width (`MANTLE_FIT`, lifted 6 cm: it sits on top of the shoulders and changes the silhouette; the Mourner's pale mantles get a brighter dress); chests of other sets (and legendary ones) show none, only the trim tint.
  - Helms and mantles use `DmCreature.attach_fitted(bone, prop, {offset, yaw})`: seated from the rig's rest pose in the hero's own axes (+X forward, +Y up, +Z right) so the bone's own axes do not matter, sized from `region_fit` (the box of the vertices skinned to the Head / chest bones, measured once per rig). Rigid on the bone, nothing per frame.
  - *Legendary sets*: at 3+ worn pieces of a legendary set the whole body becomes that set's `hero_leg_*` model (`DmAvatar._swap_body`, from `set_look_changed`): the weapon, helm (re-fitted), mantle, cape, aura, lantern and tints move to the new body, which keeps standing / walking; below 3 pieces the hero's own body returns.
    The Reaper never swaps (she keeps her body; aura and set colours still apply). `DmAvatar.slug` is always the hero's own body, `body_slug` the one showing. The two-piece look prefetches the model on a worker thread (`DmGearModels.prefetch`) and the warm-up keeps the local discipline's legendary body resident, so the swap is a few ms.
    `RIG_HEAD` and `CULL_BACK_SLUGS` list the legendary bodies (colossus_mantle and plague_choir are closed bodies and cull back faces; legion_unburied 3.2% and requiem_wraiths 18.6% open edges stay double-sided).
- **Body gear**: `set_region_tint` washes a region lightly (strength 0.28-0.42 by rarity, `DmGearFx.LOOK`, a covered head 40% of that) so the model's texture keeps its detail; the piece's glow
  (tier glow, else a dim of its colour, else the set scheme's accent) only lights trim (bright texture detail) and rim in `DmCreatureMat`.
- **Weapon glow** (`DmGearFx.dress_weapon`, on gear change): the tip halo grows with rarity (common/uncommon as modelled, rare x1.3, epic x1.6, legendary x1.8), rare+ add a rarity-coloured outer halo and
  5 / 10 / 16 motes (cap 16, one CPUParticles3D (GPU-simulated particles are a B12 crash suspect), world-space so a swing leaves a streak); an element (`DmGearFx.ELEMENTS`: the metal tier's, or the socketed runes' via `set_weapon_element`) tints the motes with the
  matching spell colour and shows at least 4 motes. Low graphics (`Vfx.quality`) keeps halos, drops particles.
- **Set look** (`DmAvatar.set_look(set_id, pieces)`, called by `set_equipment` with the set having most worn pieces): aura motes (6 at 2-3 pieces, 14 at 4+, one emitter) and, from 3 pieces, the set's colour scheme;
  `set_look_changed(set_id, pieces)` is the hook the legendary body swap listens to (3+ pieces).
- Tests: `tests/gear_look/run.gd` (every kind's model, length and grip; helm / mantle mounts, sizes and clips; the legendary swap), `tests/next_hero_look/run.gd` (the real bag path and the remote peer).

## Tests
Suites in `godot/tests/`: `gear_look/` (held props, tint, rarity / element / set effects), `game/` (auto combat, gather, labor, graphics presets), `rewards/`, `rules-loot/`, `next_bag/`, `next_perfctl/`
and the `next_*` suites that exercise these classes through DmNextGame. Run one with
`godot --headless --path godot --script res://tests/<suite>/run.gd`.

## Known gaps
- Occlusion: world walls and props use dither shaders (`world/dm_occ_*.gdshader`); floors and gates are not cut.
