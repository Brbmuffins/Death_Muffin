# UI host contract: `DmNextUiHost` <-> `DmGameUi`

`DmGameUi` (`godot/game_ui/dm_game_ui.gd`) builds the HUD, every panel, counsel, dialogue, settings and chat. It talks to
the game only through a host node passed to `setup(game)`. In the game that host is `DmNextUiHost`
(`godot/next/hud/dm_next_ui_host.gd`, child `UiHost` of `DmNextGame`), which feeds the UI from the game's nodes.
`godot/game_ui/mock_game.gd` implements the same surface for UI tests. Optional calls are made through `has_method`
guards, so a host without them still works. Last checked against the code 2026-10-09.

## What the host provides

Properties (read by the UI): `api` (`DmApi`, the authenticated session), `character` (server character dictionary), `slots`
(bag + equipped slots, read-only to the UI), `progress` (necro progress state), `settings` (persisted settings keys), `area_id`,
`release`, `party_code`, `dev_account`, `camera`.

Methods the UI calls: `cast(slot)`, `use_belt(slot)`, `navigate(x, z)`, `set_auto_combat(on)`, `buy_upgrade(kind)`;
`refresh_character()`, `refresh_inventory()`, `refresh_progress()` (re-fetch, then emit the matching signal);
`bag_remove(slot_index, item_id, n) -> int`, `bag_sort(on_moves, is_locked)`, `bag_commit() -> String` ("" = saved, else the reason);
`apply_settings(s)` (store, persist, push to audio / Vfx / camera); `hud_state() -> Dictionary` (live numbers: hp, essence,
cooldowns per slot, buffs, target, boss, wave, kill chain, thralls, minimap, Depths readout; built by `DmNextHudVm`);
`use_item(id)`, `set_belt(slot, id)`, `set_rites(primary, keys)`, `near_grinder()`, `counsel_busy()`, `counsel_tick_ctx()`,
`stop_gathering(reason)`, `afk_active()`, `afk_status()`, `start_afk(node_id)`, `stop_player()`, `talk_key()`, `travel(area_id)`,
`dial_wave(delta)`, `send_chat(text)`, `leave_world()`, `class_changed(character)`, `party_create()`, `party_join(code)`,
`party_leave()`, `summon_boss(id)`, `summon_boss_empowered(id)`, `enter_depths(depth)`.

Signals the UI listens to: `character_changed`, `inventory_changed`, `progress_changed`, `area_changed(id)`, `hero_died`,
`hero_respawned`, `npc_interact(npc_id)`, `station_interact(station_id)`, and `game_event(event_id, ctx)`.

`game_event` carries every moment that raises a counsel tip, toast, banner, loot line, floating text or chat line: `toast`,
`banner`, `loot`, `float`, `chat`, `hit_flash`, `slot_flash`, `codex`, `gather_report`, `boss_key_offer`, `depths_stair_offer`, and
the counsel event ids in `DmCounselEvents` (`godot/next/hud/README.md` lists which the game raises).

## Rules

- The UI never assigns `slots`; bag changes go through `bag_remove` / `bag_sort` / `bag_commit`.
- Panel actions call `game.api` and then the matching `refresh_*()`.
- `DmGameUi` handles the panel keys itself (physical keys, no input actions); movement, rite keys and the Chapterhouse keys
  stay with the game (`DmNextInput`, `DmRiteHotbar`).
- Change this surface only together with `DmNextUiHost`, `mock_game.gd` and the suites in `tests/next_hud*`.
