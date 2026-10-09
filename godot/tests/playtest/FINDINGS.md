# Godot client playtest findings

Harness: `tools/godot/playtest.sh` (one discipline, session A = every flow + window-close save, session B = relaunch and compare),
`tools/godot/playtest-all.sh` (Gravecaller 2, Ossuary 1, Mourner 3, Rotweaver 4). Bot: `godot/tests/playtest/bot_next.gd`. Offline (`--dev-offline`) only,
isolated `XDG_DATA_HOME` per run, no live server. Tree tested: godot/playtest = game-core + the archive/godot-port line (merge 234cdf87). Runs 2026-10-05.

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

---

# Rebuild playtest (`DmNextGame`, `-- --next`), compared with the current game

Harness: `tools/godot/playtest.sh --next [--disc=N] [--boss=a,b] [--sessionA-only]` drives the rebuild through `tests/playtest/bot_next.gd` (the twin of `bot.gd`);
`tools/godot/playtest-all.sh --next` runs the four necromancer disciplines; `tools/godot/playtest-compare.py` prints the rebuild-vs-current table from
`out/nd<N>_h` and `out/d<N>_h`. Headless, offline edition, isolated `XDG_DATA_HOME`, time scale 3, `--warmup` (the rebuild's `DmNextWarmup` runs, as in play).
Both bots now write the same `metrics` block into the report JSON. Tree: godot/playtest-next on archive/godot-next 8441daf4. Runs 2026-10-06/07.

Flows the rebuild bot drives (real key / mouse events pushed into a 1280x800 SubViewport): login screen -> register -> discipline card -> loading cover -> world; all 14
panel keys open / Esc / toggle; Settings via Esc; walk Chapterhouse -> Graves by click-to-move; a controlled damage probe; a 75 s fight (LMB click-attack on the nearest enemy,
hotbar keys 1-4, RMB, R, flask under 45% hp); loot walk + equip / unequip through the Reliquary; level-up through the real xp path; boss summon with E at the grave + kill;
forced death + respawn; window-close save; relaunch (session B: resume, compare level / xp / gold / equipped / graves kills / boss kills / bag / class / id) + a 20 s fight.
Not covered on the rebuild (the current bot does them): Warren seal + Depths, Recall, contract check (the rebuild has no `DmGame` contract; it is `DmNextUiHost`).

Assists (noted in the report, never hidden): level 30 for the boss through `progress.grant_xp` (the real xp path, so it persists), 99 shards, hp floor 35% in the boss fight.

## Comparison (headless, 75 s manual fight at level 1 unless stated; "rebuild" = two runs r1 / r2, "current" = one run)

| discipline | kills | gold gain | xp gain | deaths | min hp (fight) | flasks | Gravedigger kill (s) | relaunch fight kills (20 s) | single robber TTK (s) | pack of 6 TTK (s) |
|---|---|---|---|---|---|---|---|---|---|---|
| Ossuary 1 | 96 / 106 vs 105 | 989 / 2093 vs 1853 | 658 / 622 vs 629 | 0 / 0 vs 0 | 0.71 / 0.33 vs 0.72 | 0 / 5 vs 0 | 53.7 / 53.2 vs 54.4 | 32 / 34 vs 29 | 1.3-1.7 vs 1.3-1.7 | 4.5 / 4.1 vs 4.3 |
| Gravecaller 2 | 90 / 70 vs 60 | 747 / 834 vs 227 | 603 / 424 vs 430 | 0 / 2 vs 0 | 0.31 / 0.00 vs 1.00 | 7 / 0 vs 0 | 56.4 / 47.8 vs 41.9 | 34 / 29 vs 25 | 1.4-1.8 vs 1.7-1.8 | 4.3 / 4.9 vs 7.4 |
| Mourner 3 | 88 / 99 vs 56 | 851 / 886 vs 686 | 465 / 586 vs 401 | 1 / 0 vs 0 | 0.10 / 0.42 vs 0.82 | 5 / 1 vs 0 | 54.9 / 55.8 vs 55.2 | 31 / 32 vs 28 | 0.9-1.4 vs 1.3-1.4 | 3.0 / 2.8 vs 4.8 |
| Rotweaver 4 | 94 / 91 vs 76 | 852 / 1062 vs 689 | 469 / 618 vs 364 | 0 / 1 vs 0 | 0.56 / 0.10 vs 0.72 | 0 / 2 vs 0 | 48.8 / 48.9 vs 44.6 | 30 / 34 vs 29 | 0.9-1.4 vs 1.3-1.5 | 2.9 / 2.9 vs 4.5 |

Other rows, same on both: level-1 hp 100, enemy average hp 65-77 and damage 8-11 per enemy, thrall caps (3 / 5 / 3 / 3), enemies seen in the fight (rebuild 119-134, current 102-131),
max enemies alive 13-46, boss deaths 0, persistence 100% (see below). Frames (wall clock, loaded shared box, so only the shape matters): p50 7.8-10.8 ms rebuild vs 8.8-10.3 current, p95 15-29 vs 19-27;
play frames over 100 ms: rebuild 0-20 (0 on every quiet run), current 0-24 (the same machine noise hits both); worst play frame 63-321 ms rebuild vs 86-543 current. No systematic frame-cost difference.
Gold differences are the 100-kill chain milestone (+1000 gold at 100 kills in one chain): the run that reaches it shows ~+2000, the one that stops at 98 does not.
Bosses on the rebuild (disc 2, level-30 assist): Gravedigger 47-56 s, Abbess 87-132 s, Drowned Congregation 143-167 s, Prelate 279-280 s, all with 0 hero deaths and the kill recorded in the chronicle.
Saint / Regent / Mire: the bot hero (506 hp at level 30, standing in melee, no dodge) dies to the burst and the boss goes back to sleep (reported as minor "not defeated", chronicle count unchanged); the current game's bot never beat them either.

## Findings, ranked

### 1. FIXED (rebuild bug): the click-attack's primary repeat stalled after one cast whenever the essence pool was full
`DmCombatInput` repeats the primary through `DmRiteCaster.cooldown_left(primary)`. On the host `cooldown_left` read the replicated `_state` snapshot, which `_push_state(false)` re-sends **only when the
essence changed**. The primary is free (Bone Needle costs nothing), so at a full pool the snapshot kept its first-sent 380 ms cooldown for ever: one left click on an enemy cast once and then stood there
(measured: a lone robber took 16 s to kill, by which time it had killed the hero; the bar's cooldown never cleared either). Anyone fighting with the primary alone, or with a full pool, felt "my attack
stops". Fix: the host reads its own timeline (`p["cooldowns"] - _now_ms`), `next/rites/dm_rite_caster.gd`. Test: `tests/next_playtest` (1: cooldown runs down with a full pool; 2: one click kills a robber with 3+ primary casts).
After the fix: single robber 0.9-1.8 s, identical to the current game's 1.3-1.8 s.

### 2. FIXED (rebuild, shared widget): the first tooltip of a session logged an engine error and was misplaced for a frame
`DmTip.of()` adds its layer to the root with `call_deferred`, so the first `show_anchor` ran `_place()` on a card that was not in the tree yet (`get_viewport_rect: !is_inside_tree()`; Rect2() -> a (0,0) viewport
for one placement). Seen when the mouse sat on a hotbar slot while a fight started. Fix: `_place()` returns until the card is in the tree (`_process` places it every frame anyway), `ui/widgets/dm_tip.gd`. Test `tests/next_playtest` (3).

### 3. BOT artefacts found and fixed (not product bugs)
- **The current bot's headless left clicks never attacked.** The headless viewport has no 3D hover pick, so `hover` stays null and `DmGameInput.on_primary_click` (which re-reads it) turned every
  bot click into a ground click: the old bot's kills came from the hotbar keys alone, which made the current game look 3-5x slower and deadlier in a first comparison (19-46 kills vs 100, 1-3 deaths, Gravedigger 76-115 s
  vs 43-59 s). `bot.gd` now sets `attack_target` directly (`_attack_click`), in the fight and the boss loop. The rebuild's `_primary_click` picks the enemy from the click position itself, so its clicks were real all along.
  This also means the numbers in sections 7 and 8 above (deaths per 75 s, boss durations) describe a key-only hero.
- Click-to-move to a loot drop that lies on unwalkable ground (a scatter next to a wall) is counted (`metrics.loot_unreachable`, a note), not reported as a movement bug.
- The boss-phase level assist ran 29 level-ups in one frame (a 200-300 ms bot-made hitch); it now yields a frame per level. A first-use hitch at the Gravedigger's first sweep (200-250 ms, always at ~4 s) was
  `res://assets/fx/binbun/rend_impact.tscn` + `crescent.webp` loading mid-fight because headless skipped `DmNextWarmup`; with `--warmup` (as in play) it is gone.
- `boss defeated` is now the chronicle's count rising, not "the boss is no longer active" (a wipe also deactivates it).
- A relaunch/old-bot assumption that the Warren is still sealed at the start of the seal phase: the faster click-attack bot breaks it first; now a note.
- Session B's `max_thralls` / `max_enemies` no longer overwrite session A's in the comparison.

### 4. OPEN (needs the owner's judgement, probably balance): the rebuild's level-1 hero is hit much more than the current game's
In the same 75 s fight the rebuild hero's lowest hp is 0.00-0.71 (median 0.32, flasks 0-7, deaths in 3 of 8 runs: 1-2 each) against 0.72-1.0 on the current game (flasks 0, deaths 0). Enemy hp / damage per enemy, kill speed,
thrall caps and the number of enemies seen are equal, so it is contact: the rebuild director spawns a wave 9-14 m from the hero, inside the 15 m aggro range ("so a wave notices the hero at once", `dm_wave_director.gd`),
while the sim spawns at breaches and walks them in. The first hour is an owner priority; if the current feel is the target, widen `SPAWN_MIN/MAX` or stagger the pack. (Run-to-run variance is large, so read the direction, not the digits: it held in all 8 rebuild runs.)

### 5. OPEN, minor: boss adds and wave loads are not covered without the warm-up
Without `DmNextWarmup` (headless default, or a build that skips it) the first Command Rend impact costs a 200-250 ms frame (`rend_impact`, `crescent`): `DmRiteFx.BINBUN_IDS` (the per-rite preload list) does not name
`rend_impact`. Harmless while the warm-up runs (it warms every effect), but a cheap addition to `BINBUN_IDS` would make the cold path safe too. Not changed here (shared `game/` file; no player-visible effect).

### 6. Persistence, death, loot, gold, xp (all pass, 8 of 8 rebuild sessions)
Session B after the window-close save: level, xp, gold, equipped set, bag quantity, Graves kills, boss kills (chronicle), class, character id all equal; a 20 s fight afterwards kills 29-34 (current: 25-29). Lethal hit: one death, dead hero does
not walk, respawn in the Chapterhouse after 4 s with hp > 0, nothing lost. Walking over drops picks them up (3-6 items per run); gold and xp never fall; no script errors, no `hp`/resource out of range.
The only engine error in a rebuild run was finding 2 (the current game's runs log 1-2 as well).
