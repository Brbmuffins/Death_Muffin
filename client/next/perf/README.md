# client/next/perf: performance controls + GPU warm-up + the benchmark

`DmNextPerf` (child `Perf` of `DmNextGame`, `game.perf`): the Settings panel's graphics, fps cap and auto-resolution settings.
`apply(settings)` runs in `start()` (the player's settings file, read only; a bare scene gets High's defaults) and on every Settings change (`DmNextUiHost`).
- `graphics` is the preset (`DmGraphicsPreset`: Low, Medium, High, Ultra; what each sets and how the lift of each area sits on top: "Graphics presets" below). The RenderingServer
  is told only what changed (`DmGraphicsPreset.apply_render`): setting the soft-shadow filter, even to the value it has, makes Godot 4.7.2 drop every compiled
  pipeline, so a new game and every Settings apply used to throw away what the warm-up had compiled. A preset change still compiles again (it must).
  `client/tools/compile_probe.gd` counts the pipelines each fresh game compiles on the VPS's software Vulkan (one short run; `--why` checks the re-apply steps). Low: no moon shadows, no bloom, halved weather, `Vfx.quality = "low"`; High and Ultra
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
compiles mid-play: what it draws, and why it started running for players on 2026-10-17, is [BENCHMARK-REPORT.md](BENCHMARK-REPORT.md) ("The warm-up"). The stage and effect handles are freed afterwards. The loaded model scenes stay held (`DmWarmup.hold`) so no model loads
from disk in play, except the hero kits of the greyed-out disciplines: `DmWarmup.release_unused_heroes` drops them (kept = `DmWarmup.hero_slugs_in_play()`: the playable disciplines' kits, the local hero's, and the `necromancer` fallback). `DmNextWarmup.last_ms` holds the time.

Test: `client/tests/warm_coverage.gd` fails when play uses a material that was not drawn while warming. It notes every material the scene tree gets (a node's a frame after it enters, the whole tree after each step) by what makes its shader (the Shader, a StandardMaterial3D's modes, flags and texture slots,
a particle material's shader-changing properties, a sprite's flags, `next_pass`); what is seen until `start` returns counts as warmed. Play, in a fresh warm-up game of each of the five disciplines: every hotbar slot cast (and as a crit), a fight, loot, the hero hurt and healed, worn gear and pets; the Gravecaller and the Reaper cast
their whole kit, the Gravecaller meets the boss and waves. Each gap prints its node, script, scene, discipline and rite; `-- --list` prints every signature. Not covered: lighting variants (the area tour's job), other graphics presets and areas, the panels.

Textures used in 3D are imported VRAM Compressed (`compress/mode=2`, normal maps RGTC; `textures/vram_compression/import_s3tc_bptc` and the phone formats are on in `client/project.godot`); `npm run hygiene` enforces it.
Test hooks: `DmModels.cold_loads`, `DmGearModels.cold_loads`, `DmFxBinbun.cold_loads` count first loads from disk (0 after a warm-up).

## Benchmark (testers: same fight on every PC)

`DmBenchmark` (`dm_benchmark.gd` and the `dm_bench_*.gd` files beside it): the Benchmark button on the character select or `godot -- --benchmark`.
Its setup, run, report and upload: [BENCHMARK.md](BENCHMARK.md); reading the report: [BENCHMARK-REPORT.md](BENCHMARK-REPORT.md).

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
The VPS processor test is the benchmark run headless at `--fixed-fps 60` ([BENCHMARK.md](BENCHMARK.md)); the suites print per-system timings as `INFO` lines and never assert them (only deterministic counters are checks).

## Graphics presets

Low, Medium, High and Ultra on Forward+ (DECISIONS B45; the preset ids are the old game's, so a saved setting carried over): `game/dm_graphics_preset.gd` is the table and `next/perf/dm_next_perf.gd` (`DmNextPerf`, the game scene's `perf`)
applies it. The game scene reads the player's settings file at the start and the
Settings panel applies a change live, `opts.settings` in tests and the benchmark. A preset sets the moon's shadow, reach, splits
and atlas and the soft filter, bloom (`DmWfxBloom`), screen-space ambient occlusion (High and Ultra), MSAA, anisotropy and mesh LOD on the viewport, the effects quality
and the Binbun layer, the crowd's shadow policy (`DmCrowd.set_shadow_policy`: the nearest enemies that cast, and whether thralls cast; a change reaches the
thralls already drawn) and the floor of Auto resolution, whose lower scales are upscaled with FSR 1. Brightness, fps cap, V-Sync, window mode and interface size are
settings of their own. A preset has no prop-light count or prop shadow range (the area's lights are baked into its lightmap), and the brightness lift is Forward+'s own: an exposure multiplier of each area (`DmWorldBuilder.AREA_LIFT`, 0.8 to 2.1,
calibrated so that each area is as bright as the old game's, [The look on Forward+](../look/README.md)), eased in over 0.8 s when the hero enters another area (`LIFT_BLEND`; nothing runs per frame outside the blend),
times the preset's own factor (`DmGraphicsPreset` `lift`: 1, and 0.96 on Low, whose moon casts no shadow); the creatures' and the effects' shaders divide the lift out again (the global `dm_lift_inv`, declared in `project.godot`), because they are not in the lightmap it is calibrated on. `tests/presets.gd` (`--fixed-fps 60`, about 30 s) applies
each preset to a running game and checks the lights, the environment (the ACES tonemapper, the exposure from the world's number, the area's easing, the area's lift, the preset's factor and the brightness, the
plain-colour ambient, the depth fog, the moon and the rim light at their energies), viewport, crowd shadows and the governor, the twelve lifts (a number here is a calibration: measure again with the probe before changing it), the blend and what the lift leaves alone (`dm_lift_inv` follows it through a blend, the creature material's, the crowd's and the effects' shaders divide it out and convert their colours as Compatibility does, the hero's ring and shadow strength).
