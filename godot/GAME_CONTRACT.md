# DmGame ↔ DmGameUi contract (integration, 2026-10-04)

Two tracks integrate the port in parallel. **game-core** owns `godot/main/`, `godot/world/`, `godot/game/`;
**game-ui** owns `godot/game_ui/`. This file is the seam; change it only by agreement (the integrator merges).

## DmGame (`godot/game/dm_game.gd`, built by game-core; the in-world root node)
Properties (read by the UI):
- `api: DmApi` — the authenticated session from `DmFrontFlow.enter_world`.
- `character: Dictionary` — the server character (level, xp, gold, shards, stats, discipline/classIndex, …) as `DmApi` returns it.
- `slots: Array` — bag + equipped slots in the `DmBag`/`DmLoot` shape the Reliquary already consumes.
- `progress: Dictionary` — necro progress state (vows, unlocks, run, unlockedAreas, chronicle…) as the server stores it.
- `settings: Dictionary` — web settings keys (same keys/defaults as the web `settings.ts`), persisted by game-core.
- `sim: DmWorldSim`, `hero_id: int`, `area_id: String`, `in_depths: bool`.
- `lootview: DmLootView`, `camera: Camera3D`.
Methods (called by the UI):
- `cast(slot: int)`, `use_belt(slot: String)`, `navigate(x: float, z: float)`, `set_auto_combat(on: bool)`, `buy_upgrade(kind: String)`.
- `refresh_character()`, `refresh_inventory()`, `refresh_progress()` — re-fetch from the server, then emit the matching signal.
- `apply_settings(s: Dictionary)` — store, persist and push to AudioDirector / Vfx / camera.
- `hud_state() -> Dictionary` — sim-derived live numbers the HUD needs (hp, max_hp, essence, cooldowns per slot, buffs,
  target, boss, wave/surge, kill chain, thrall count, minimap entities, depths readout). Shape = the HUD view-model in
  `godot/ui/hud/README.md` minus the parts the UI owns (menus, toasts, panels, Next box, tips).
Signals (listened to by the UI):
- `character_changed`, `inventory_changed`, `progress_changed`, `area_changed(id)`, `hero_died`, `hero_respawned`.
- `game_event(event_id: String, ctx: Dictionary)` — every moment the web fires a counsel tip, toast, banner, loot toast,
  float text or chat line (ids from `godot/ui/onboarding/README.md` plus `toast`, `banner`, `loot`, `float`, `chat`).
- `npc_interact(npc_id: String)`, `station_interact(station_id: String)` — the player used an NPC/station (opens dialogue/panels).

## DmGameUi (`godot/game_ui/dm_game_ui.gd`, built by game-ui; a CanvasLayer child of DmGame)
- `setup(game: DmGame)`; builds DmHud, every panel, DmCounsel + view, guidance Next box, dialogue, settings, chat.
- Each frame: `hud.apply(merge(game.hud_state(), ui-owned parts))`.
- Panel actions call `game.api` exactly as the web panels call the REST client, then `game.refresh_*()`.

## Additions by game-ui (2026-10-04) — all OPTIONAL: DmGameUi calls them through `has_method` guards, so a DmGame without them still works
Properties: `release: String`, `party_code: String`, `dev_account: bool`.
Methods the UI calls (game-core implements; the web equivalents in parentheses):
- `use_item(item_id)` (drinkFlask/eatMeal/drinkBuff: Reliquary double-click / Drink / Eat), `set_belt(slot, item_id)` (UI owns the pick in its store and tells the game), `set_rites(primary: String, keys: Array)` (Grimoire changes; the UI persists `dm_loadout_v2_<id>`; HUD `slots` must follow).
- `near_grinder() -> bool` (Bone Grinder range), `counsel_busy() -> {combat, hurt, dead}` (lastCombatAt/lastHurtAt bookkeeping), `counsel_tick_ctx() -> Dictionary` (every 400 ms, DmCounselEvents.tick_calls ctx).
- `stop_gathering(reason)`, `afk_active() -> bool`, `afk_status() -> {active, text, allowed}`, `start_afk(node_id)`, `stop_player()`, `talk_key()` (E key), `travel(area_id)` (Waystones), `dial_wave(delta)`, `send_chat(text)`.
- `leave_world()` (Settings), `class_changed(character)`, `party_create()`, `party_join(code)`, `party_leave()`, `summon_boss(id)`, `summon_boss_empowered(id)`, `enter_depths(depth)`.
`game_event` payloads drawn by the UI: `toast {text, kind}`, `banner {title, sub, ms}`, `loot {name, qty, rarity}`, `float {text, kind, color?, world: Vector3 | screen: Vector2}`, `chat {text}`, `hit_flash`, `slot_flash {slot}`, `codex {kind: dead|area, id}`, `gather_report {report}` (opens the Sexton's Ledger), `boss_key_offer {boss, seals, gold, shards, bound}`, `depths_stair_offer {deepest}`; every other id is a counsel event id (`ui/onboarding/README.md`).
`progress` is the LocalProgress shape (`DmProgression.blank()` keys: damageTier, waveTierOwned, legionTier, shards, areaKills, unlocked, totalKills, ascension, ashes, boons, vows, unlocks, run).
`hud_state()` should include `brews` (the Q/Z/X tray), `slots` (primary + hotbar), `minimap`, etc. per `ui/hud/README.md`; the UI adds `reveal`, `new`, `grimoire_new`, `next`, `dev`, slot `swap` flags.
Keys: DmGameUi handles I B J Y C P O U H N V M K . L G Enter E Esc and the loadout hotkeys itself (physical keys, no input actions); keys 1-6 R Q Z X T and WASD stay with game-core.
