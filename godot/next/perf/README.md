# godot/next/perf: performance controls + GPU warm-up

`DmNextPerf` (child `Perf` of `DmNextGame`, `game.perf`): the Settings panel's graphics, fps cap and auto-resolution settings.
`apply(settings)` runs in `start()` (`opts.settings`, default High / uncapped / auto_res on) and on every Settings change (`DmNextUiHost`).
- `graphics` low: no moon shadows, no bloom, 3 prop lights (8 on High), halved weather, `Vfx.quality = "low"`.
- Moon shadow casters: `DmCasterBudget` every 0.5 s keeps the nearest 12 enemies (8 with 32+ alive) casting on High (Medium 8/6, Ultra 20/14, Low none); the hero, thralls and bosses always cast.
- `physics/common/max_physics_steps_per_frame=3` (project.godot; Godot default 8): a frame that falls behind catches up at most 3 physics steps,
  so a very slow moment slows the game briefly instead of spiralling (8 catch-up steps made each slow frame slower; the benchmark froze for good).
- `fps`: `Engine.max_fps` (0 = uncapped; the governor judges against the cap, or 60 for Max).
- `vsync` (default on): `DisplayServer.window_set_vsync_mode`, only when it changes; skipped headless.
- `auto_res`: `DmResolutionGovernor`  on the root viewport's `scaling_3d_scale`; `pace(dt)` per frame once `ready_` (real renderer only),
  `hold()` on every area entry. A graphics / fps / auto_res change restarts it at 1.0 and holds.
- Prop culling cells (12 m), shadow range (32 m), streaming and light LOD are `DmWorldBuilder`'s, driven every frame by `DmNextWorld.update`.
  They run on cached typed arrays (area rects, light positions / nodes, shadow cells) with no per-call allocation: the light budget is the
  `light_near`-th smallest squared distance of a native sort, only lights whose state changes are written (`_lights_dirty` is set wherever
  `prop_lights` changes), and the 4 Hz shadow-cell re-check is spread over frames (`SC_CHUNK` cells each; one full pass when `dt` is 0).

`DmNextWarmup.run(game)` (end of `start()`, under `DmWarmup`'s cover; default on with a real renderer, `opts.warmup` forces it): threaded loads of every model +
Binbun scene; one body per distinct slug of every enemy kind / thrall / legion / boss (opaque, elite emissive, mid-fade, thrall gear + spectral variants), every Binbun
effect, every decal / flash layer, the enemy and boss telegraph shapes; then the tour of all 13 areas (the stage travels with the camera; per stop: lit, with every point
light hidden = Godot's separate "no omni light" variant, and with the shared flash light on). The stage and effect handles are freed afterwards. The loaded model scenes stay held (`DmWarmup.hold`) so no model loads from disk in play, except the hero kits
of the greyed-out disciplines: `DmWarmup.release_unused_heroes` drops them (kept = `DmWarmup.hero_slugs_in_play()`: the playable disciplines' kits, the local hero's, and the
`necromancer` fallback). `DmNextWarmup.last_ms` holds the time.

Textures used in 3D are imported VRAM Compressed (`compress/mode=2`, normal maps RGTC; `textures/vram_compression/import_s3tc_bptc` is on in project.godot); `npm run hygiene` enforces it.
Test hooks: `DmModels.cold_loads`, `DmFxBinbun.cold_loads` count first loads from disk (0 after a warm-up).
Tests: `tests/next_perfctl/run.gd`. Rendered probe: `tests/next_perfctl/entry_probe.gd` (header has the command).

## Benchmark (testers: same fight on every PC)

`DmBenchmark` (`dm_benchmark.gd`, setup window `dm_benchmark_setup.gd`, UI `dm_benchmark_screen.gd`, run history + upload `dm_bench_history.gd`, shared fight setup
`dm_bench_fight.gd`, also used by `tests/perf/fight_breakdown.gd`). Run it from the **Benchmark** button (bottom right of the character select screen: the setup
window, then the run; Back returns there) or `godot -- --benchmark` (results screen with a Quit button; `--bench-room=<area> --bench-class=<index>
--bench-size=light|standard|heavy|full_party --bench-length=quick|full` pick the setup, `--bench-warm=<s> --bench-measure=<s>` shorten it for smoke runs).
- Setup (`configure`, remembered per PC in `user://benchmarks/setup.json`): room = any combat area (`ROOMS`, not the Depths) with its own enemy kinds and their
  abilities; class = the playable disciplines (`class_indices`: the four necromancers + the Reaper); size Light 15 enemies / 10 thralls, Standard 30 / 20, Heavy
  60 / 30, Full Party 72 / 32 and a boss (`SIZES`; the director's body limit is raised to 100 so a Heavy or Full Party fight's corpses don't stall spawning); length Quick (6 s warm-up, 20 s measured, no
  render breakdown) or Full (10 s + 30 s + breakdown). `STANDARD` (Bell Sanctum, Gravecaller, Standard, Full) is the setup that compares PCs; any other
  is labelled custom in the window, the report and the history.
- **Full Party** is the biggest fight today's game can make, the one the rebuild's gates are measured on: 72 enemies (the global enemy cap, `DmSimData.GLOBAL_ENEMY_CAP`;
  the test keeps `SIZES` equal to it), 32 thralls (4 necromancers' legions of 8, all raised for the one hero), and the room's boss held awake (`BOSS_SIZES`). A boss only
  wakes for heroes standing in its own area, so the boss is the room's own (`DmBenchFight.boss_of`): the Bell Sanctum's Bell-Sworn Prelate in the Standard room, whose
  13 m arena fills the 36 x 28 m room; the Warren and the Coliseum have no boss and run Full Party without one (the setup window, the report and the history say so).
  The boss is woken through the real summon (the hero stands at its site with the shards it costs granted to the throwaway character, then goes back; `DmBenchFight.hold_boss`)
  and again after each defeat, so its brain, adds, effects, rewards and drops cost what they cost in play; the report has a Boss line (woken / defeated, share of the
  measured window awake) and the upload carries `boss_awake_pct`. The boss keeps its own health; its adds count as enemies (held at 72 by the same trim) and have the standard health.
  Not in it: the three co-op guests' hero bodies. A guest is a session peer with its own caster, rewards member and backend session; a body outside the session is neither
  targeted by enemies nor counted by the boss (enemies and boss brains read `session.get_bodies()`), so a stand-in would add a skeleton but no part of a guest's load.
  Runs upload like every other size (size id `full_party`; the backend's `SIZES` and the history page know it, so deploy the backend before the client that sends it).
- Same toughness everywhere: every enemy gets `standard_stats()` hp and damage whatever its kind, room or raiser (`DmWaveDirector.fixed_stats`, no elites):
  the Bell Sanctum roster's spawn-weighted average at its level on Easy (273 hp), so the kill rate matches the old Sanctum fight and kills cost the same in
  every room; what differs between rooms is the creatures, their abilities and the room itself. Esc cancels (also during the paused breakdown). The player has no control during the run: the screen sits on a layer above the HUD and takes every click, and every input callback of the fight is switched off; auto combat casts with `hold_position` (no walking) and a hero moved by a rite is put back at the centre.
- Isolated: an in-memory `DmOffline` mock backend, nothing persisted, no network, the HUD's `dm_ui.json` kept in memory; the player's settings file is only read
  (graphics preset and fps cap go into the report; the run uses the preset). During the run V-Sync is off, `Engine.max_fps` 0 and auto resolution off; V-Sync, the fps cap
  and the render scale are restored afterwards (also on Esc).
- Fight: the picked room (its seal broken for the throwaway character, since a sealed area has its navmesh off; the walkable point nearest the centre that a path joins to the doorway), the real wave director with its spawn distance brought in to 6-14 m (play: 18-30 m, which in a small room is only the far corners) and its cap at the size's count, topped up every 0.25 s and trimmed back (raisers add Risen past the cap: the farthest extras vanish, no death or reward), kills, corpses and loot drops costing what they cost in play, god-mode level 60 hero of the picked class on auto combat (Easy), thralls raised directly, seed 20261011,
  camera zoom 1.0. Warm-up 10 s (not measured: the first frames compile shaders), then 30 s measured. If the measured fight runs at the screen's refresh rate the report warns that
  V-Sync is still on (often forced in the GPU driver) instead of showing capped numbers as real, and the history flags the run; a paused breakdown at the
  refresh rate (a fast PC, light frozen picture) only notes that the breakdown's ms columns are capped.
- Measured: average fps, average / median / p95 / p99 / worst frame ms, hitches over 50 ms, average draw calls / objects / primitives
  (`RenderingServer.get_rendering_info`), render CPU and GPU ms (`viewport_get_measured_render_time_*`), `TIME_PROCESS` / `TIME_PHYSICS_PROCESS`, enemy and thrall counts.
  The report header has the game version (`DmBuild.version()`: the `manifest.json` the launcher installs next to the exe, "dev" otherwise), GPU, renderer, resolution, preset, fps cap setting, CPU and thread count.
- Render breakdown (after the measured window, ~45 s; a big centred "FIGHT FROZEN ON PURPOSE" banner with the step and the time left covers it, `breakdown_step`): the fight is paused (the picture stays) and moon
  shadows, thralls, enemies, the world (ground, props, area meshes), effects and last the HUD are hidden one at a time, then everything-on is measured
  again (a drift note when the two disagree) for 5 s each (1 s settle); the table lists how many draw calls, ms of render CPU / GPU
  and frame time each part costs on that PC. Visibility only, restored after each sample (`tests/next_bench` checks it).
- Hitch log: every measured frame over 50 ms with what happened in it (kills, spawns, first-time model / effect loads from `DmModels`,
  `DmFxBinbun`, `DmGearModels` `cold_loads`), plus average loot drops and corpses on the ground. Breakdown rows whose ms rose when the part
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
- Test: `tests/next_bench/run.gd` (three short runs: the Standard setup, a custom one and a Full Party fight at its real size with the Prelate; same enemy health in
  every room, history, upload queue against fake servers, setup window and launch args; deterministic checks only).

## Reading the F3 overlay

The F3 overlay splits the frame: `tick` is the game tick by system, `fx` the `Vfx` autoload, `ui` the HUD and counsel, `outside`
the rest (engine animation, culling, draw submission, GPU wait). If `outside` dominates, look at `calls` / `objects` and `render
cpu`; if sim or views grow with enemies, it is script cost. Only numbers from a real GPU count: the VPS runs software GL at about
7 fps. Probes: `tests/perf/` (`fight_breakdown.gd`: a held Hollow Graves fight; main-thread CPU per frame, a knock-out table per system; `--full-party` runs the
benchmark's Full Party fight instead (Bell Sanctum, 72 enemies, 32 thralls, the Prelate, the benchmark's own director, upkeep and enemy health: `DmBenchFight.arm` / `upkeep`) and is the
VPS processor test: `nice -n 10 godot --headless --fixed-fps 60 --path godot --script res://tests/perf/fight_breakdown.gd -- --full-party --reps=0 --seg=1200` prints
`FB base cpu= wall= p50= p95=` (main-thread CPU and wall ms per frame, no GPU), `--boss=none` and `--n= --thralls=` vary it, leave out `--reps=0` for the knock-out table; `tools/godot/profile.py` runs any probe under Godot's script profiler for per-function times), `tests/next/render_probe.gd`; the `tests/next*` suites print per-system timings as `INFO perf:` lines and never assert them (only deterministic counters are checks).
