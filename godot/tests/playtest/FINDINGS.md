# Godot client playtest findings

Harness: `tools/godot/playtest.sh` (one discipline, session A = every flow + window-close save, session B = relaunch and compare),
`tools/godot/playtest-all.sh` (Gravecaller 2, Ossuary 1, Mourner 3, Rotweaver 4). Bot: `godot/tests/playtest/bot.gd`. Offline edition only,
isolated `XDG_DATA_HOME` per run, no live server. Tree tested: godot/playtest = game-core + godot-port (merge 234cdf87). Runs 2026-10-05.

Flows covered per discipline (headless, real key/mouse events pushed into a 1280x800 SubViewport): front flow register + create, every panel key
(I J Y C P O U H N V M K . L) open / Esc / toggle, Settings via Esc, Acre -> Chapterhouse -> Graves by minimap travel, 75 s manual fight (mouse
aim, hotbar keys, RMB, R, flasks, Exhume), loot pickup, equip/unequip through the Reliquary, level up, Warren seal (150 kills), walk through the
broken gate, Depths floor 1 clear, chest, stair to depth 2, death in the Depths, respawn, resume-at-deepest prompt + enter, way up, boss fight
to defeat (Gravecaller path), forced death + respawn, save, relaunch + compare (level, xp, gold, equipped, seals, kills, peak depth, bag).
All four disciplines complete every flow; session B persistence checks pass on all four.

Assists (noted, not hidden): level raised to 15 before the Depths, level 30 + 99 shards + hp floor 35% for boss fights, 5 flasks topped up
when out. Not covered: auto combat (offline characters have `auto_combat_allowed` false), co-op, gathering/crafting/vault/contracts/garden/labor/vows/boons
(offline routes still 501 on this tree: known, not counted), web-side comparison (nothing looked off enough to need it beyond the items below).

## Ranked findings

### 1. MAJOR: world-interaction clicks open no window (`panel_toggle` is never handled by the UI)
Repro: `game.game_event.emit("panel_toggle", {"panel": "map"})` (also ascension, salvage, codex): nothing opens. Real emitters: Waystone, Altar of
Ascension, Bone Grinder, Lectern, Vault/Forge/Workbench clicks (`game/dm_game_actions.gd:264-292`, `game/dm_game_input.gd:98-143`).
Cause: `DmGameUi._on_game_event` (`game_ui/dm_game_ui.gd:461`) has no `"panel_toggle"` case and falls to `counsel.notify`.
Patch: `"panel_toggle": toggle_panel(String(ctx.get("panel", "")))` (respect `open_only` for labor). Hotkeys work (UI handles keys itself); only clicking the world objects is dead.

### 2. MAJOR: game `tip(...)` events are dropped
`DmGame.tip()` emits `"tip" {id, delay_ms, opts}` (`game/dm_game.gd`), UI has no case, so every scripted counsel tip the game raises is lost.
Patch: `"tip": counsel.show(String(ctx.get("id","")), float(ctx.get("delay_ms",0)), ctx.get("opts"))` in `_on_game_event`.

### 3. MAJOR: F3 performance overlay does nothing
`main/perf_overlay.gd` (`DmPerfOverlay`) is never instantiated; README controls promise F3. Patch: `add_child(DmPerfOverlay.new())` in `DmMain._ready`.
(The harness adds its own and computes wall-clock frame stats.)

### 4. MINOR (headless only): `SCRIPT ERROR: Trying to assign an array of type "Array" to a variable of type "Array[Plane]"`
`fx/dm_fx_binbun.gd:404`, `var planes: Array[Plane] = cam.get_frustum()` every frame while binbun effects live. Seen in every `--headless` run (dummy renderer
returns an untyped array); NOT seen in the rendered (xvfb) run. Spams the log (hundreds per run) and fails any headless QA that treats SCRIPT ERROR as fatal.
Patch: `var planes: Array[Plane] = []; if cam != null: planes.assign(cam.get_frustum())`.

### 5. UNCONFIRMED, 1 of 8 runs: gold rewound by 40 (477 -> 437) with no purchase (Mourner, during the Warren-seal fight)
Suspect a stale `refresh_character()` response overwriting locally credited gold (pickup/milestone credited between request and reply). Watch for it; the bot flags any gold decrease not marked as a purchase.

### 6. UNCONFIRMED, minor: T (Recall) not started 0.5 s after the press in 3 of 4 headless runs (not Rotweaver), once loot pickup missed 2 drops (1 of 8)
Bot clears attack target and stops the hero before T, so Recall being cancelled (hurt, or `moved`) while enemies are on top of the hero is the likely cause; compare with web behaviour before acting.

### 7. Numbers worth a look (balance, not bugs)
- Level-1 necromancers die 2 times per 75 s in the Graves with the bot (Rotweaver 0); 0 ms vs 300 ms reaction delay: 26-57 kills vs 18 kills, deaths 2-3 vs 3. Pressure exists but the slow bot is only mildly worse.
- Gravedigger dies in ~85-130 s of game time, Abbess ~170 s (level 30 hero), both with 0 hero deaths.
- Boss sweep beyond those two is inconclusive (bot hero dies, later bosses fail to wake because the previous boss is still active): not product bugs.

### 8. Performance (relative only, llvmpipe/dummy renderer; headless frame time is logic cost, not GPU)
Per run 5-6k frames: p50 17.4-17.8 ms, p95 25-27 ms, p99 34-37 ms, worst ~580 ms (identical in all runs: a one-off hitch, probably Depths floor build or boss wake; investigate with the in-game overlay on a real GPU), 26-32 frames over 50 ms per run.
Enemy count peaks 64-68 (Depths floor spawns 56 at once). A rendered full run (xvfb, ~7 fps) takes over 25 min and times out in the boss phase: use `--skip-to` or run headless for the full sweep.
Wall-clock load of the world: 2.8-4.8 s headless.

### Fixed in game-core while this pass ran (found by the harness earlier, no action needed)
counsel_tick unknown-event warning every 0.4 s; `game.panel_open` not following UI windows (combat input not gated); DmGame lacked `set_rites`, `dial_wave`, `enter_depths`, `stop_gathering`, `afk_*`, `party_*`, `summon_boss_empowered`... (contract check `_p_contract` now passes); stair event names (`depths_stair_offer`, `boss_key_offer`) mismatched; `death` event removed.

## Harness notes
- Headless `--script` root is 64x64 and ignores pushed mouse events: the bot hosts Main in a 1280x800 `SubViewport` and pushes input there.
- `Engine.time_scale` 3 for headless; frame stats use wall-clock deltas.
- After a merge the class cache must be refreshed: `playtest.sh` runs `--import` when HEAD changes.
- Options: `--disc=N --boss=id|all|a,b --skip-to=depths|boss --delay=MS --rendered --scale=N --sessionA-only`.
