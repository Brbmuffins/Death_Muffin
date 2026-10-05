# godot/game: the in-world game (port of src/scenes/WorldScene.ts and friends)

`DmGame` (dm_game.gd) is the in-world root. `await game.start(character, api, opts)` builds the world (DmWorldBuilder), the sim (DmWorldSim at the frame's dt, clamped to 0.1 s like the web),
the hero (DmPlayer body + DmAbilitySystem caster), input, entity views, loot, progression + inventory saves, areas, death / respawn.
`opts`: `visual` (false = headless: no world nodes, camera or Vfx; tests), `persist` (false = nothing under user://), `local_progress` (offline edition: progression stays local),
`seed`, `name`, `settings_path`. Headless drive: `game.tick(dt)`. Seam with the UI: `godot/GAME_CONTRACT.md`.

| file | web source |
|---|---|
| dm_game.gd | WorldScene mount / update / areas / settings / contract surface |
| dm_game_input.gd | bindInput, updateCursor (picking), onPrimaryClick, castSlot, tickCombat (queued casts, held keys, Easy auto), minimap travel |
| dm_game_rewards.gd | onKill, dropItems + LootRoller, collected, gainXp, chain tiers, milestones, seals (checkUnlocks), boss / surge rewards, first-kill trophies |
| dm_game_combat.gd | onHurt (wards, barrier, Bulwark), onDeath, legend sync, Bonded Dead, bossBusy refunds |
| dm_game_actions.gd | flasks / meals / brews / belt, Recall, waystone travel, interact (stations, NPCs, bosses, stairs), boss summons (+ Empowered) |
| dm_game_gather.gd | Skills + GatherLoop hooks, node visuals |
| dm_game_hud.gd | updateHud: `hud_state()` view-model (ui/hud/README.md shape) |
| dm_player.gd | Player.ts (walking half; numbers live in the DmPlayerRules state) |
| dm_progress_sync.gd, dm_inventory.gd | the network halves of Progression and Inventory |
| dm_settings.gd, dm_loadout.gd, dm_keybinds.gd, dm_hitstop.gd, dm_fen_rules.gd | settings.ts, loadout.ts, keybinds.ts, hitstop.ts, fen.ts |
| dm_ability_system.gd | AbilitySystem visual half (extends DmSimCaster) |
| dm_entity_views.gd, dm_boss_view.gd, dm_avatar.gd, dm_creature*.gd, dm_gear_props.gd | EntityViews, BossView, NecromancerAvatar, Creature |
| dm_event_fx*.gd | handleEventNow / telegraph / zoneVisual / boss events (visual + audio half) |
| dm_auto_combat.gd, dm_auto_dodge.gd, dm_boss_telegraphs.gd | autoCombat.ts, autoDodge.ts |
| dm_gather_loop.gd, dm_skills.gd, dm_node_views.gd | Gathering.ts, NodeViews.ts |
| dm_depths_controller.gd | DepthsController.ts (Phase B) |
| dm_offline.gd, dm_basic_ui.gd | the offline edition's mock backend + a fallback HUD until game_ui is merged |

## Contract status (godot/GAME_CONTRACT.md)
Everything in the contract and in "Additions by game-ui" is implemented: properties (`settings` uses the Settings panel's keys, see dm_settings.gd), `hud_state()` (brews, slots, minimap, target, boss,
chain, depth, party, omen, prompt), the optional methods (`use_item`, `set_belt(slot, item)`, `set_rites`, `near_grinder`, `counsel_busy`, `counsel_tick_ctx`, `stop_gathering`, `afk_*`, `start_afk`,
`stop_player`, `talk_key`, `travel`, `dial_wave`, `send_chat`, `leave_world`, `class_changed(character)` (emits `world_restart` for main), `party_create/join/leave`, `summon_boss(_empowered)`,
`enter_depths`), and the `game_event` payloads (`toast`, `banner`, `loot {name, qty, rarity}`, `float {world: Vector3, text, kind, color?}`, `chat`, `codex {kind, id}`, `gather_report {report}`,
`boss_key_offer`, `depths_stair_offer {deepest}`, `hit_flash`, `slot_flash`, every other id = a counsel event).
Game-core additions the UI may use: `game.ui` (set by main; gives the game `panel_open`, `dialogue_open`, `next_active`), `game.npc_new` (npc id -> has news, set from the UI's guidance memory),
`game.hotbar / loadout / primary`, `game.set_primary(id)`, `game.set_rite(slot, id)`, `game.do_ascend() / do_swear(vows) / do_open(key)`, `game.flush_all()`, `game.prog / psync / inventory / chronicle`,
`game.coop` (co-op), `game.apply_cosmetics(selected)` (called after `refresh_character()`).
Keys: DmGame owns 1-6 R Q Z X T WASD / arrows and the mouse (LMB click / hold-shift, RMB = slot 5, wheel zoom); every other key belongs to DmGameUi.

## Not ported / placeholders
- Occlusion is ported as dither shaders on walls and props (world/dm_occ_*.gdshader), applied to the builder's materials; floors and gates are not cut.
- Co-op needs the live relay for a real session; it is tested through an in-process relay (tests/game/coop_run.gd). Perf beacon, release watcher (web reload prompt) and the DEV debug hooks are not ported.
- The offline edition runs on godot/net/dm_mock_backend.gd, a port of src/net/mockBackend.ts covering every route the game calls (persisted under user://).
