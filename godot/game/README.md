# godot/game: shared in-world classes

The old in-world root `DmGame` (and its input, combat, actions, coop, ability-system and depths-controller helpers) was deleted on
2026-10-09. The rebuild root is `DmNextGame` (`godot/next/`). This folder keeps the classes DmNextGame and the UI still use.
Several file headers still say "DmGame" or cite web `WorldScene.ts`; read those as history.

| group | files |
|---|---|
| Views | `dm_creature*.gd`, `dm_avatar.gd`, `dm_entity_views.gd`, `dm_boss_view.gd`, `dm_pet_view.gd`, `dm_npc_views.gd`, `dm_node_views.gd`, `dm_laborer_views.gd`, `dm_gear_props.gd`. Model rows come from `view_models.json` |
| Player | `dm_player.gd` (walking body), `dm_loadout.gd`, `dm_inventory.gd`, `dm_progress_sync.gd` (debounced saves to the backend) |
| Combat helpers | `dm_auto_combat.gd`, `dm_auto_dodge.gd`, `dm_boss_telegraphs.gd`, `dm_fdlibm_x.gd`, `dm_hitstop.gd`, `dm_rite_fx.gd` |
| Rewards / HUD model | `dm_game_rewards.gd` (kill drops, XP, chain), `dm_game_hud.gd` (HUD view-model, shape in `ui/hud/README.md`) |
| Gathering / labor | `dm_gather_loop.gd`, `dm_gather_session.gd`, `dm_skills.gd`, `dm_game_labor.gd` |
| Settings / perf | `dm_settings.gd`, `dm_graphics_preset.gd`, `dm_resolution_governor.gd`, `dm_warmup.gd` |
| Offline | `dm_offline.gd`: mock backend with the item catalogue, used by `-- --dev-offline` and by tests |

`dm_event_fx.gd` and `dm_event_fx_{boss,telegraph,zones}.gd` (`DmEventFx`) are the event-to-VFX/audio router, written for the old DmGame host.
It is still used: `next/enemy_fx/dm_enemy_fx.gd` creates one with a reduced host (`dm_enemy_fx_host.gd`) for enemy telegraphs, deaths and voices.
Parts of it (sim-record lookups, remote players) are unreachable now.

## Tests
Suites in `godot/tests/`: `game/` (auto combat, gather, labor, graphics presets), `rewards/`, `rules-loot/`, `next_bag/`, `next_perfctl/`
and the `next_*` suites that exercise these classes through DmNextGame. Run one with
`godot --headless --path godot --script res://tests/<suite>/run.gd`.

## Known gaps
- `DmEventFx` carries code paths for the deleted host (sim records, mirror, abilities); only the enemy-fx subset is reachable.
- `tests/game/` still has files named for the old flow (`flow_run.gd`, `exit_run.gd`, ...); check they still run before trusting them.
- Occlusion: world walls and props use dither shaders (`world/dm_occ_*.gdshader`); floors and gates are not cut.
