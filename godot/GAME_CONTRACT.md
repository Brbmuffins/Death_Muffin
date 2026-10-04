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
