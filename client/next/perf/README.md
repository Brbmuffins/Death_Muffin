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

`DmNextWarmup.run(game)` (end of `start()`, under `DmWarmup`'s cover; on by default for players, off headless and on a QA run (`--qa`, `--shot-plan=`), `--warmup` forces it, `opts.warmup` overrides it) draws every model, effect, crowd model at its three levels of detail, telegraph shape, shot and area's lighting once so nothing
compiles mid-play: what it draws, and why it started running for players on 2026-10-17, is client/README.md "The benchmark" ("The warm-up"). The stage and effect handles are freed afterwards. The loaded model scenes stay held (`DmWarmup.hold`) so no model loads
from disk in play, except the hero kits of the greyed-out disciplines: `DmWarmup.release_unused_heroes` drops them (kept = `DmWarmup.hero_slugs_in_play()`: the playable disciplines' kits, the local hero's, and the `necromancer` fallback). `DmNextWarmup.last_ms` holds the time.

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

## Reading the F3 overlay

The F3 overlay (`client/main/perf_overlay.gd`, key rebindable in Settings > Controls) shows: fps and the frame times over the last 5 s with the hitches over 50 ms; `logic` (the frame's real process and physics parts, averaged over the last second by `DmFrameSplit`, and the slowest
tick) against `render cpu` and `gpu`; `fx` (the `Vfx` autoload's own node time a frame); draw calls, objects, primitives, texture memory and nodes; the graphics card, resolution, memory. If `logic` dominates, it is script or core cost (the benchmark's budget section splits the
core's tick from the rest); if the render rows dominate, look at `calls` / `objects` and the benchmark's render breakdown. Only numbers from a real GPU count: the VPS runs software GL at about 7 fps. The old per-system `tick` and `ui` lines are not in the client's overlay.
The VPS processor test is the benchmark run headless at `--fixed-fps 60` (client/README.md "The benchmark"); `python3 tools/godot/profile.py --project client -- <script>` runs a script under Godot's script profiler for per-function times; the suites print per-system timings as `INFO` lines and never assert them (only deterministic counters are checks).
