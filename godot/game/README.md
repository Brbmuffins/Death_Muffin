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

## Tests
Suites in `godot/tests/`: `game/` (auto combat, gather, labor, graphics presets), `rewards/`, `rules-loot/`, `next_bag/`, `next_perfctl/`
and the `next_*` suites that exercise these classes through DmNextGame. Run one with
`godot --headless --path godot --script res://tests/<suite>/run.gd`.

## Known gaps
- Occlusion: world walls and props use dither shaders (`world/dm_occ_*.gdshader`); floors and gates are not cut.
