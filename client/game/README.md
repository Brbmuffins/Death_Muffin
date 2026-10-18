# client/game: shared in-world classes

Shared classes that `DmNextGame` (`client/next/`) and the UI use. Some file headers still say "DmGame" or cite `WorldScene.ts`; the root is `DmNextGame`.
Enemies and thralls are not drawn here: the crowd draws them (client/crowd/README.md), so there is no per-creature view class.

| group | files |
|---|---|
| Views | `dm_creature*.gd` (the hero, bosses, hub people, laborers and pets are skeleton nodes), `dm_avatar.gd`, `dm_boss_view.gd`, `dm_pet_view.gd`, `dm_npc_views.gd`, `dm_node_views.gd`, `dm_laborer_views.gd`, `dm_gear_props.gd`. Model rows come from `view_models.json` (the crowd's baker reads them too) |
| Player | `dm_loadout.gd`, `dm_inventory.gd`, `dm_progress_sync.gd` (debounced saves to the backend) |
| Combat helpers | `dm_auto_combat.gd` and `dm_auto_dodge.gd` (Easy auto combat's decisions: `client/next/feel/README.md`), `dm_boss_telegraphs.gd`, `dm_fdlibm_x.gd`, `dm_hitstop.gd`, `dm_rite_fx.gd` |
| Leftovers | `dm_game_hud.gd`: only the static `DmGameHud.art(path)` icon helper and `interact_prompt` are in the client's copy (the HUD view-model is `DmNextHudVm`, shape in `client/ui/hud/README.md`). `dm_game_rewards.gd` is used only for its kill-range rule (`DmSessionRewards` keeps an instance); the rest of it and `dm_player.gd` are not called by the live game; live rewards are `client/next/rewards/` |
| Gathering / labor | `dm_gather_loop.gd`, `dm_gather_session.gd`, `dm_skills.gd`, `dm_game_labor.gd` |
| Settings / perf | `dm_settings.gd`, `dm_graphics_preset.gd`, `dm_resolution_governor.gd`, `dm_warmup.gd` |
| Offline | `dm_offline.gd`: mock backend with the item catalogue, used by `-- --dev-offline` and by tests |

`dm_event_fx.gd` and `dm_event_fx_{boss,telegraph,zones}.gd` (`DmEventFx`) are the event-to-VFX/audio router, written for the old DmGame host.
Only two subsets are reachable, each created with a reduced host: `client/next/enemy_fx/dm_enemy_fx.gd` (`dm_enemy_fx_host.gd`) for enemy telegraphs, deaths, voices and zones, and `client/next/bosses/dm_boss_fx.gd` for boss events; the sim-record, mirror and ability code paths are dead.

## Creature rendering
`DmCreatureMat` is the one creature shader of the skeleton nodes (the hero, bosses, hub people, laborers); the crowd's enemies and thralls use `client/crowd/crowd_vat.gdshader`, which takes the same colour rules
(client/crowd/README.md "Differences from the creature material"; client/README.md "The look against today's game" for the colours and the exposure lift both divide out). Models in `CULL_BACK_SLUGS` (closed glTF bodies: under 2% open edges, winding agrees
with the normals) render back-face culled; every other model, and every winged or spectral body, stays `cull_disabled` (hair cards, cloaks, open robes, thin cloth). Add a slug only after checking its mesh is closed.
Only the nearest enemies cast into the moon shadow: the crowd's shadow policy (`DmCrowd.set_shadow_policy`, counts per preset in `DmGraphicsPreset`, applied by `DmNextPerf`; client/crowd/README.md "Crowd cost"); the hero and bosses always cast, thralls cast unless the preset has no shadows.
The boss light and the shared Binbun flash light are `visible = false` while their energy is zero.

## Creature animation (`dm_creature.gd`)
For the skeleton nodes; the crowd plays baked clips and redoes the procedural layer below for the core's creatures (client/crowd/README.md "What each creature does"). The AnimationPlayer is advanced by hand (`update(dt)`: animation LOD, hitstop). Blends: swing in over 0.3 x its wind-up (0.06-0.14 s), flinch 0.09, death 0.12, back to the loop 0.2, idle/walk/run 0.28.
Walk and run are stride-matched (`set_ground_speed`, allocation-free plan). Idle starts at a random phase and +-8% rate per non-hero body so a crowd does not breathe in step.
A procedural layer rides the single model node (no skeleton work, `_fx_step` runs only while one is active, `busy()` keeps it at full rate): hit recoil (`react`, fired by a fresh `set_flash(1)`
and by `flinch`), strike lunge timed to the clip's impact (`play_strike`; the hounds, which have no attack clip, lunge and bite with the body alone), `topple` for rigs with no death clip
(eased 0.45 s, then the pose freezes), `set_rise` (spawn climb). Boss swings use `play_strike` so a 6.6 s clip never plays out its tail.

## Held props and gear look (`dm_creature.gd`, `dm_gear_props.gd`, `dm_gear_models.gd`, `dm_gear_fx.gd`, `dm_avatar.gd`)
- **Held props** (`DmCreature.attach_held(bone, prop, spec)`; the hero's staff, worn weapons and off-hands): the prop's origin (its grip point, moved `hold` metres up its +Y)
  sits on the palm centre measured once per rig from the skinned hand vertices (`palm_of`; the rigs have no finger bones), its +Y along the knuckle line (hand-local X, mirrored for the
  left hand) leaned `lean` degrees toward the fingers and rolled `roll` about itself. It is a rigid child of the bone attachment, so it follows the hand exactly with no script per frame (the older `attach(bone, obj, dir, follow)` with its
  world-up lock and calibration is for tools and glows; thralls' hand props are baked into the crowd: client/crowd/README.md "Hand props"). `DmGearProps.HOLDS` is the per-kind table (staff, scythe, wand, sickle, skull_focus, mourning_bell, grimoire/tome, sword, dagger, mace,
  bow, shield, default_staff); a model made later needs a row there (or gets `HOLD_DEFAULT`) and a grip at its origin with its long axis +Y. Tuning a kind: render it (idle, run, cast) and adjust lean / roll / hold.
- **Real gear models** (`DmGearModels`, table `client/data/slice/necro_gear.json`; props are `models/props/necro_*.glb`, one mesh, one material, one draw call each):
  - *Weapons*: the seven necromancer kinds (and the default staff, in the bone tier with the discipline's soul-light) are the real models, scaled to the table's `length_m` and seated so the shaft at `grip_t` (measured from the model's vertices at that height, `shaft_at`: a scythe's
    shaft is not the middle of its bounds) is at the origin; a `tip` meta node marks the top end (the spell origin). The metal tiers (bone, iron, gold, hell, moon) are one model each in a subtle tint (within 0.85-1.1 per channel, the model's texture stays) and a low emission accent (`TIER_DRESS`, k <= 0.4, following the
    texture's bright detail), one shared material per (model, tier). The Reaper keeps her own scythe.
  - *Helm*: the head slot shows the tier helm model (`helm_tier_of`: a set with its own `helm_by_tier` row keyed by its set id shows that helm (Soul Harbinger's Raiment: `gear_greenbone_helm`); other set heads by collection, class sets iron, ascended silver, legendary hellsteel; `helm_copper` / `helm_iron` copper / iron, `helm_gold` silver), over the rig's own hood (the hood stays; the head region also keeps its faint trim tint). Hide helms hides the model.
    The model is 1.5x the measured head height (`HELM_FIT`) and sits 0.03 m above the head's top (`HELM_OVER`).
  - *Mantle*: a chest piece of any set with a `mantle_by_set_id` row (class sets and their ascended sets) shows that set's mantle on the upper body, 1.65x the measured chest width (`MANTLE_FIT`, lifted 6 cm: it sits on top of the shoulders and changes the silhouette; the Mourner's pale mantles get a brighter dress); chests of other sets show none, only the trim tint.
  - Helms and mantles use `DmCreature.attach_fitted(bone, prop, {offset, yaw})`: seated from the rig's rest pose in the hero's own axes (+X forward, +Y up, +Z right) so the bone's own axes do not matter, sized from `region_fit` (the box of the vertices skinned to the Head / chest bones, measured once per rig). Rigid on the bone, nothing per frame.
  - *Legendary sets*: at 3+ worn pieces of a legendary set the whole body becomes that set's `hero_leg_*` model (`DmAvatar._swap_body`, from `set_look_changed`): the weapon, helm (re-fitted), mantle, cape, aura, lantern and tints move to the new body, which keeps standing / walking; below 3 pieces the hero's own body returns.
    The Reaper swaps only to her own set's body (Soul Harbinger's Raiment → `hero_leg_soul_harbingers`); other sets give her the aura and set colours. A body with `covers_props` already wears its set's hood and ribcage, so that set's helm and mantle props hide while it shows, and `rim` gives it a soft edge glow in the set colour (Soul Harbinger: green, strength 0.5). A set can also give her its own scythe: `weapon_by_set_id` (kind, prop, pieces) swaps the scythe she carries and the one in hand from that many pieces (`DmAvatar._reseat_scythe`; Soul Harbinger's Raiment: `gear_greenbone_scythe` from 3). `DmAvatar.slug` is always the hero's own body, `body_slug` the one showing. The two-piece look prefetches the model on a worker thread (`DmGearModels.prefetch`) and the warm-up keeps the local discipline's legendary body resident, so the swap is a few ms.
    `RIG_HEAD` and `CULL_BACK_SLUGS` list the legendary bodies (colossus_mantle and plague_choir are closed bodies and cull back faces; legion_unburied 3.2% and requiem_wraiths 18.6% open edges stay double-sided).
- **Body gear**: `set_region_tint` washes a region lightly (strength 0.28-0.42 by rarity, `DmGearFx.LOOK`, a covered head 40% of that) so the model's texture keeps its detail; the piece's glow
  (tier glow, else a dim of its colour, else the set scheme's accent) only lights trim (bright texture detail) and rim in `DmCreatureMat`.
- **Weapon glow** (`DmGearFx.dress_weapon`, on gear change): the tip halo grows with rarity (common/uncommon as modelled, rare x1.3, epic x1.6, legendary x1.8), rare+ add a rarity-coloured outer halo and
  5 / 10 / 16 motes (cap 16, one CPUParticles3D (GPU-simulated particles are a B12 crash suspect), world-space so a swing leaves a streak); an element (`DmGearFx.ELEMENTS`: the metal tier's, or the socketed runes' via `set_weapon_element`) tints the motes with the
  matching spell colour and shows at least 4 motes. Low graphics (`Vfx.quality`) keeps halos, drops particles.
- **Set look** (`DmAvatar.set_look(set_id, pieces)`, called by `set_equipment` with the set having most worn pieces): aura motes (6 at 2-3 pieces, 14 at 4+, one emitter) and, from 3 pieces, the set's colour scheme;
  `set_look_changed(set_id, pieces)` is the hook the legendary body swap listens to (3+ pieces).

## Tests
The client suites that exercise these classes through the game scene (client/README.md "Set up and test"): `client/tests/rites.gd` (the Reaper's set look: Soul Harbinger's hood, body and scythe), `auto_combat.gd`
(Easy auto combat), `gathering.gd` (the gather loop, skills, laborers), `presets.gd` (the graphics presets), `rewards.gd` and `value.gd` (rewards), `panels.gd` (the Reliquary and the bag) and `game_scene.gd`.
Not covered in the client: held-prop grips and clips, helm and mantle mounts and sizes, tint, rarity, element and set effects, the legendary body swap (the old game's gear-look suite) and the creature
animation blends and procedural layer.

## Known gaps
- See-through cutout: `DmNextWorld` switches the builder's `occlusion_enabled` off, so the wall and prop shaders (`client/world/dm_occ_*.gdshader`) cut nothing in any area or Depths floor
  (client/README.md "Areas"); with it on, floors and gates are not cut.
