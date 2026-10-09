# godot/game: shared in-world classes

Shared classes that `DmNextGame` (`godot/next/`) and the UI use. Some file headers still say "DmGame" or cite `WorldScene.ts`; the root is `DmNextGame`.

| group | files |
|---|---|
| Views | `dm_creature*.gd`, `dm_avatar.gd`, `dm_entity_views.gd`, `dm_boss_view.gd`, `dm_pet_view.gd`, `dm_npc_views.gd`, `dm_node_views.gd`, `dm_laborer_views.gd`, `dm_gear_props.gd`. Model rows come from `view_models.json` |
| Player | `dm_loadout.gd`, `dm_inventory.gd`, `dm_progress_sync.gd` (debounced saves to the backend) |
| Combat helpers | `dm_auto_combat.gd`, `dm_auto_dodge.gd`, `dm_boss_telegraphs.gd`, `dm_fdlibm_x.gd`, `dm_hitstop.gd`, `dm_rite_fx.gd` |
| Leftovers | `dm_game_hud.gd`: only the static `DmGameHud.art(path)` icon helper is used (the HUD view-model is `DmNextHudVm`, shape in `ui/hud/README.md`). `dm_game_rewards.gd` and `dm_player.gd` are not called by the live game (`tests/rewards` uses them); live rewards are `next/rewards/` |
| Gathering / labor | `dm_gather_loop.gd`, `dm_gather_session.gd`, `dm_skills.gd`, `dm_game_labor.gd` |
| Settings / perf | `dm_settings.gd`, `dm_graphics_preset.gd`, `dm_resolution_governor.gd`, `dm_warmup.gd` |
| Offline | `dm_offline.gd`: mock backend with the item catalogue, used by `-- --dev-offline` and by tests |

`dm_event_fx.gd` and `dm_event_fx_{boss,telegraph,zones}.gd` (`DmEventFx`) are the event-to-VFX/audio router, written for the old DmGame host.
Only the enemy-fx subset is reachable: `next/enemy_fx/dm_enemy_fx.gd` creates one with a reduced host (`dm_enemy_fx_host.gd`) for enemy telegraphs, deaths and voices; the sim-record, mirror and ability code paths are dead.

## Tests
Suites in `godot/tests/`: `game/` (auto combat, gather, labor, graphics presets), `rewards/`, `rules-loot/`, `next_bag/`, `next_perfctl/`
and the `next_*` suites that exercise these classes through DmNextGame. Run one with
`godot --headless --path godot --script res://tests/<suite>/run.gd`.

## Known gaps
- Occlusion: world walls and props use dither shaders (`world/dm_occ_*.gdshader`); floors and gates are not cut.
