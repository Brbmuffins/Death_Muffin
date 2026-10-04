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

## Additions to GAME_CONTRACT.md (UI track: read this)
- `game_event` ids the game emits besides the contract's: `panel_toggle {panel}` (inventory sheet legion forge professions contracts garden labor cosmetics vault map codex atlas grimoire
  ascension salvage settings; the UI opens/closes that window), `escape {panel_open}` (close the open panel, else open Settings), `chat_focus`, `slot_flash {slot}`, `hit_flash`, `chain_pulse`,
  `death {show, sub}`, `loadout_hotkey {action}` (a rebound loadout key: apply that preset), `boss_key_prompt {boss, seals, gold, shards, bound}` (open the BossKeyPrompt; answer with
  `game.call_empowered(id)` or `game.summon_boss(id)`), `depths_stair_prompt {resume}`, `grimoire_pulse`, `upgrade_bought {kind}`, `gather_reply`, `gather_stopped {reason}`, `dialogue_close`,
  plus every counsel event id of ui/onboarding/README.md and `tip {id, delay_ms, opts}`. `toast` may carry `action: "grimoire"`.
- UI -> game: `game.panel_open` (set true while a window is open: gates combat input), `game.dialogue_open`, `game.next_active` (the Next line shows), `game.use_item(id)`, `game.set_belt(id)`,
  `game.belt_choices(slot)`, `game.set_primary(id)`, `game.set_rite(slot, id)`, `game.hotbar / loadout / primary / seen`, `game.travel(area)`, `game.start_recall()`, `game.talk_to(npc)`,
  `game.do_ascend() / do_swear(vows) / do_open(key)`, `game.set_wave_tier(t)`, `game.change_class(index) -> error`, `game.leave_world()`, `game.flush_all()`, `game.keybinds`, `game.store`
  (DmCounselStore for local per-character records), `game.prog / psync / inventory / chronicle / gatherer.skills` (the state objects the panels read).
- `hud_state()` follows ui/hud/README.md; icons are `res://assets/game/art/...` (tools/godot/sync-game-art.sh copies them from public/art).
