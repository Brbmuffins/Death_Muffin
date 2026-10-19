# client/next/perf: performance controls + GPU warm-up + the benchmark

`DmNextPerf` (child `Perf` of `DmNextGame`, `game.perf`): the Settings panel's graphics, fps cap and auto-resolution settings.
`apply(settings)` runs in `start()` (the player's settings file, read only; a bare scene gets High's defaults) and on every Settings change (`DmNextUiHost`).
- `graphics` is the preset (`DmGraphicsPreset`: Low, Medium, High, Ultra; what each sets and how the lift of each area sits on top: client/README.md "Graphics presets"). Low: no moon shadows, no bloom, halved weather, `Vfx.quality = "low"`; High and Ultra
  add the Binbun effects, ambient occlusion and the glow.
- Moon shadow casters: the crowd's shadow policy (`DmCrowd.set_shadow_policy`, client/crowd/README.md "Crowd cost") keeps the nearest 12 enemies (8 with 32+ alive) casting on High (Medium 8/6, Ultra 20/14, Low none); the hero, thralls and bosses always cast
  (thralls unless the preset has no shadows).
- `physics/common/max_physics_steps_per_frame=3` (`client/project.godot`; Godot default 8): a frame that falls behind catches up at most 3 physics steps,
  so a very slow moment slows the game briefly instead of spiralling (8 catch-up steps made each slow frame slower; the benchmark froze for good).
- `fps`: `Engine.max_fps` (0 = uncapped; the governor judges against the cap, or 60 for Max).
- `vsync` (default on): `DisplayServer.window_set_vsync_mode`, only when it changes; skipped headless.
- `auto_res`: `DmResolutionGovernor` on the root viewport's `scaling_3d_scale`, upscaled with FSR 1; `pace(dt)` per frame once `ready_` (real renderer only),
  `hold()` on every area entry. A graphics / fps / auto_res change restarts it at 1.0 and holds.
- The area scenes stay loaded and their props are instanced: there is no streaming, culling cell or light LOD (KNOWN-GAPS "Performance", "Draw calls": the props always cast the moon's shadow).

`DmNextWarmup.run(game)` (end of `start()`, under `DmWarmup`'s cover; on by default for players, off headless and on a QA run (`--qa`, `--shot-plan=`), `--warmup` forces it, `opts.warmup` overrides it) draws every model, effect, crowd model at its three levels of detail, telegraph shape, shot, dropped item (`DmLootView.warm`: icon, light pillar, glow, name), piece of worn gear (a throwaway hero in a legendary set with off-hand, cape and a flying pet) and area's lighting once so nothing
compiles mid-play: what it draws, and why it started running for players on 2026-10-17, is client/README.md "The benchmark" ("The warm-up"). The stage and effect handles are freed afterwards. The loaded model scenes stay held (`DmWarmup.hold`) so no model loads
from disk in play, except the hero kits of the greyed-out disciplines: `DmWarmup.release_unused_heroes` drops them (kept = `DmWarmup.hero_slugs_in_play()`: the playable disciplines' kits, the local hero's, and the `necromancer` fallback). `DmNextWarmup.last_ms` holds the time.

Test: `client/tests/warm_coverage.gd` fails when play uses a material that was not drawn while warming. It notes every material the scene tree gets (a node's a frame after it enters, the whole tree after each step) by what makes its shader (the Shader, a StandardMaterial3D's modes, flags and texture slots,
a particle material's shader-changing properties, a sprite's flags, `next_pass`); what is seen until `start` returns counts as warmed. Play, in a fresh warm-up game of each of the five disciplines: every hotbar slot cast (and as a crit), a fight, loot, the hero hurt and healed, worn gear and pets; the Gravecaller and the Reaper cast
their whole kit, the Gravecaller meets the boss and waves. Each gap prints its node, script, scene, discipline and rite; `-- --list` prints every signature. Not covered: lighting variants (the area tour's job), other graphics presets and areas, the panels.

Textures used in 3D are imported VRAM Compressed (`compress/mode=2`, normal maps RGTC; `textures/vram_compression/import_s3tc_bptc` and the phone formats are on in `client/project.godot`); `npm run hygiene` enforces it.
Test hooks: `DmModels.cold_loads`, `DmGearModels.cold_loads`, `DmFxBinbun.cold_loads` count first loads from disk (0 after a warm-up).

## Benchmark (testers: same fight on every PC)

`DmBenchmark` (`dm_benchmark.gd`, setup window `dm_benchmark_setup.gd`, UI `dm_benchmark_screen.gd`, run history + upload `dm_bench_history.gd`, shared fight setup
`dm_bench_fight.gd`, the frame split `dm_frame_split.gd`). Run it from the **Benchmark** button (bottom right of the character select screen: the setup
window, then the run; Back returns there) or `godot -- --benchmark`. The launch options, the rooms, the classes, the sizes, the fight's rules (the fixed seed, the god-mode hero on Easy auto combat, the same toughness for every enemy in every room), the report's
budget section, the crowd's cost counters, the headless frame pad and the world dressing's cost are all client/README.md "The benchmark".
- Setup (`configure`, remembered per PC in `user://benchmarks/setup.json`): size Light 15 enemies / 10 thralls, Standard 30 / 20, Heavy 60 / 30, Full Party 72 / 32 and the room's boss (`SIZES`; the director's body limit is raised to 100 so a Heavy or Full Party fight's corpses
  don't stall spawning). `STANDARD` (Bell Sanctum, Gravecaller, Standard, Full) is the setup that compares PCs; any other is labelled custom in the window, the report and the history.
- **Full Party** is the biggest fight the game can make, the one the performance budgets are measured on (CLAUDE.md "Performance budgets"); the report has a Boss line (woken / defeated, share of the measured window awake) and the upload carries `boss_awake_pct`.
  Not in it: the three co-op guests' hero bodies. Runs upload like every other size (size id `full_party`; the backend's `SIZES` and the history page know it, so deploy the backend before the client that sends it).
- Esc cancels (also during the paused breakdown). The player has no control during the run: the screen sits on a layer above the HUD and takes every click, and every input callback of the fight is switched off; auto combat casts with `hold_position` (no walking) and a hero moved by a rite is put back at the centre.
- Isolated: an in-memory `DmOffline` mock backend, nothing persisted, no network, the HUD's `dm_ui.json` kept in memory; the player's settings file is only read (graphics preset and fps cap go into the report; the run uses the preset). During the run V-Sync is off, `Engine.max_fps` 0 and auto resolution off; V-Sync, the fps cap
  and the render scale are restored afterwards (also on Esc). If the measured fight runs at the screen's refresh rate the report warns that V-Sync is still on (often forced in the GPU driver) instead of showing capped numbers as real, and the history flags the run; a paused breakdown at the
  refresh rate (a fast PC, light frozen picture) only notes that the breakdown's ms columns are capped.
- Measured: average fps, average / median / p95 / p99 / worst frame ms, hitches over 50 ms, average draw calls / objects / primitives
  (`RenderingServer.get_rendering_info`), render CPU and GPU ms (`viewport_get_measured_render_time_*`), `TIME_PROCESS` / `TIME_PHYSICS_PROCESS` and the frame's real split, enemy and thrall counts.
  The report header has the game version (`DmBuild.version()`: the `manifest.json` the launcher installs next to the exe, "dev" otherwise), GPU, renderer, resolution, preset, fps cap setting, CPU and thread count.
- Render breakdown (after the measured window, ~45 s; a big centred "FIGHT FROZEN ON PURPOSE" banner with the step and the time left covers it, `breakdown_step`): the fight is paused (the picture stays) and moon
  shadows, thralls, enemies, the world (ground, props, area meshes), effects and last the HUD are hidden one at a time, then everything-on is measured again (a drift note when the two disagree) for 5 s each (1 s settle); the table lists how many draw calls, ms of render CPU / GPU
  and frame time each part costs on that PC. Visibility only, restored after each sample. What the rows count: client/README.md "The draw budget".
- Hitch log: every measured frame over 50 ms with what happened in it (kills, spawns, first-time model / effect loads from `DmModels`, `DmFxBinbun`, `DmGearModels` `cold_loads`), plus average loot drops and corpses on the ground. Breakdown rows whose ms rose when the part
  was hidden are marked unsteady (GPU-queue jitter), and a GPU-bound base gets a note to trust the draw-call column over the ms ones.
- Kills per minute (measured window only) is a report row: it shows how fast a class clears, which differs by class, not by PC.
- History: `DmBenchHistory` keeps every finished run's numbers in `user://benchmarks/history.json` (200 runs); the results table's "vs last run" column is the
  change against the previous run of the same setup, GPU and preset (green better, red worse, faint under 2% or for rows that only describe the fight).
  Every finished run is also queued (`pending.json`) and sent with the player's login (`DmApi.post_benchmark` -> `POST /api/benchmarks`) to the public
  history page `muffindevelopment.com/death-muffin/benchmarks.html` (server/death-muffin/README.md). Online from character select it goes at once; a
  `--benchmark` run uses a release build's saved login; anything that fails (no login, no network, 401/409/429/5xx) stays queued and is sent the next time
  the player enters the world. V-Sync-capped or cancelled runs are sent flagged and left out of the page's trends. Dev-offline, tests and debug builds never send.
- Output: the results panel (Copy to clipboard), the log (`BENCHMARK` lines) and `user://benchmarks/bench-<datetime>.txt`. Per-frame cost is one float appended to a
  preallocated array plus a few counter reads; the fight upkeep runs at 4 Hz.
- Test: `client/tests/benchmark.gd` (short runs: the Standard setup, a custom one and a Full Party fight at its real size; the same enemy health in every room, history, the upload queue against fake servers, the setup window and launch arguments; deterministic checks only).

## Play reports (how a real session ran)

When a play session ends the game sends one small summary of how it ran and what happened (ROADMAP Phase 1, "New: play reports"), so the team sees how the game really runs on every player's PC, whether a release made it slower, and where players struggle or stop. `DmPlayReport`
(`dm_play_report.gd`) counts; `DmPlayReportQueue` (`dm_play_report_queue.gd`) keeps the files and sends. The report belongs to `DmMain` (`main.gd`, `report`), not to the game scene, because a party hand-over or a discipline change swaps the scene and the session goes on; `attach(game)` starts counting a
scene that is ready, `detach()` stops it before it leaves. The server's side is `POST /api/play-reports` (`DmApi.post_play_report`), and its page shows the reports per release beside the server's own numbers.
- **What is in it** (`DmPlayReport.build_payload`, about 600 bytes; a real one is printed by `tests/play_report.gd`): a report id made for the session; the build (`DmBuild.version()`); the seconds in the game scene (not menus, not loading, not the warm-up, not a minimized window); how it ended
  (`logout`, `switch`, `quit`, or `crash`: `disconnect` and `unknown` are the server's other values, the game sends neither yet); the area it ended in, the hero's discipline and level; the largest party (at most 4) and whether the player hosted it; the graphics preset, GPU, driver, OS and version,
  CPU threads, memory, window size, V-Sync and fps cap; every frame as a count, average, p50, p99, worst, hitches (frames over 50 ms) and a histogram of 9 buckets (<8, <12, <16.7, <25, <33.4, <50, <100, <250, >=250 ms); per area the seconds, deaths and average frame ms; the backend party session ids
  it took part in (so the server can read its own XP, gold, kills and drops over the same sessions). p50 and p99 come from the histogram by nearest rank, placed inside the bucket evenly between its smallest and largest frame (`DmPlayReport.quantile`), so a V-Sync locked bucket reads exactly.
  A frame over 10 s counts as 10 s (the PC slept), and a session under 10 s of play sends nothing.
- **Nothing personal:** no account name, email, character id, chat or file path is read; the report id is a clock stamp and two random numbers. The server keeps the account only to count players and cap spam (50 reports a day) and never returns it.
- **Cost:** no allocation and no call in the frame: a clock read and a few float and int operations (the test prints it as INFO; about 0.5 us a frame in the debug build on the VPS). Every 250 ms of counted frame time a slow tick reads the hero's `alive` flag (a death, in the area he stands in), the party session id,
  the level and whether the window is minimized (those frames are skipped; the headless server reports every window as minimized, so it is ignored there). The roster's events give the party size.
- **When it ends and is sent:** Log out, Switch character and quit end the session (`logout`, `switch`, `quit`); a hand-over does not. Ending only writes files, so quitting never waits for the network. The report in progress is saved to `user://play_reports/live-<id>.json` at 10 s of play and every minute (about 0.3 ms);
  a live file nobody has written to for 3 minutes, found at the next start, is a crash: it is queued as `crash`. Finished reports wait in `queue.json` (at most 10, the oldest dropped) and are sent oldest first with the logged-in api: right away on Log out (before the token is dropped) and on quit (after the final save), each waiting at most 2 s, and in the background at the character select (after Switch character, or a start
  with a kept login) and when a session starts (`DmPlayReportQueue.flush`). A report the server took, or refused as invalid (400, 413, 422), leaves the queue; no login, no network, 401, 429, 5xx or an older server's 404 keep it for next time. A resend carries the same report id, which the server counts once.
- **Who never sends:** `DmPlayReportQueue.records` is the one gate (`DmMain.plays_report`): a release build's online session only. Never a debug build or the editor, a script run (every test is one: `flush` also refuses a real transport from a script), the dev-offline backend, the benchmark (its game is its own and has no report), or a test's mode.
- Test: `client/tests/play_report.gd` (the numbers on known frame sequences, the contract's shape, a real offline game scene, the save and the crash, the queue's cap, sending through the mock, the gate, and `DmMain`'s own wiring on the mock).

## Reading the F3 overlay

The F3 overlay (`client/main/perf_overlay.gd`, key rebindable in Settings > Controls) shows: fps and the frame times over the last 5 s with the hitches over 50 ms; `logic` (the frame's real process and physics parts, averaged over the last second by `DmFrameSplit`, and the slowest
tick) against `render cpu` and `gpu`; `fx` (the `Vfx` autoload's own node time a frame); draw calls, objects, primitives, texture memory and nodes; the graphics card, resolution, memory. If `logic` dominates, it is script or core cost (the benchmark's budget section splits the
core's tick from the rest); if the render rows dominate, look at `calls` / `objects` and the benchmark's render breakdown. Only numbers from a real GPU count: the VPS runs software GL at about 7 fps. The old per-system `tick` and `ui` lines are not in the client's overlay.
The VPS processor test is the benchmark run headless at `--fixed-fps 60` (client/README.md "The benchmark"); the suites print per-system timings as `INFO` lines and never assert them (only deterministic counters are checks).
