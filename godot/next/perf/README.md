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

`DmBenchmark` (`dm_benchmark.gd`, UI `dm_benchmark_screen.gd`, shared fight setup `dm_bench_fight.gd`, also used by `tests/perf/fight_breakdown.gd`). Run it from the
**Benchmark** button (bottom right of the character select screen; Back returns there) or `godot -- --benchmark` (results screen with a Quit button;
`--bench-warm=<s> --bench-measure=<s>` shorten it for smoke runs). Esc cancels (also during the paused breakdown). The player has no control during the run: the screen sits on a layer above the HUD and takes every click, and every input callback of the fight is switched off; auto combat casts with `hold_position` (no walking) and a hero moved by a rite is put back at the centre.
- Isolated: an in-memory `DmOffline` mock backend, nothing persisted, no network, the HUD's `dm_ui.json` kept in memory; the player's settings file is only read
  (graphics preset and fps cap go into the report; the run uses the preset). During the run V-Sync is off, `Engine.max_fps` 0 and auto resolution off; V-Sync, the fps cap
  and the render scale are restored afterwards (also on Esc).
- Fight: the Bell Sanctum (36 x 28 m, small so the pack stays on screen; its seal broken for the throwaway character, since a sealed area has its navmesh off; the walkable point nearest the centre that a path joins to the doorway), the real wave director with its spawn distance brought in to 6-14 m (play: 18-30 m, which in this room is only the far corners) and its cap at 30, topped up to 30 every 0.25 s and trimmed back to 30 (raisers add Risen past the cap: the farthest extras vanish, no death or reward), natural enemy health (kills, corpses and loot drops cost what they cost in play), god-mode level 60 Gravecaller on auto combat (Easy), 20 thralls raised directly, seed 20261011,
  camera zoom 1.0. Warm-up 10 s (not measured: the first frames compile shaders), then 30 s measured. If the measured window (or the paused breakdown) runs at the screen's refresh rate the report warns that
  V-Sync is still on (often forced in the GPU driver) instead of showing capped numbers as real.
- Measured: average fps, average / median / p95 / p99 / worst frame ms, hitches over 50 ms, average draw calls / objects / primitives
  (`RenderingServer.get_rendering_info`), render CPU and GPU ms (`viewport_get_measured_render_time_*`), `TIME_PROCESS` / `TIME_PHYSICS_PROCESS`, enemy and thrall counts.
  The report header has build (`dm_test_build` or the game version), GPU, renderer, resolution, preset, fps cap setting, CPU and thread count.
- Render breakdown (after the measured window, ~45 s; a big centred "FIGHT FROZEN ON PURPOSE" banner with the step and the time left covers it, `breakdown_step`): the fight is paused (the picture stays) and moon
  shadows, thralls, enemies, the world (ground, props, area meshes), effects and last the HUD are hidden one at a time, then everything-on is measured
  again (a drift note when the two disagree) for 5 s each (1 s settle); the table lists how many draw calls, ms of render CPU / GPU
  and frame time each part costs on that PC. Visibility only, restored after each sample (`tests/next_bench` checks it).
- Hitch log: every measured frame over 50 ms with what happened in it (kills, spawns, first-time model / effect loads from `DmModels`,
  `DmFxBinbun`, `DmGearModels` `cold_loads`), plus average loot drops and corpses on the ground. Breakdown rows whose ms rose when the part
  was hidden are marked unsteady (GPU-queue jitter), and a GPU-bound base gets a note to trust the draw-call column over the ms ones.
- Output: the results panel (Copy to clipboard), the log (`BENCHMARK` lines) and `user://benchmarks/bench-<datetime>.txt`. Per-frame cost is one float appended to a
  preallocated array plus a few counter reads; the fight upkeep runs at 4 Hz.
- Test: `tests/next_bench/run.gd` (short run, deterministic checks only).

## Reading the F3 overlay

The F3 overlay splits the frame: `tick` is the game tick by system, `fx` the `Vfx` autoload, `ui` the HUD and counsel, `outside`
the rest (engine animation, culling, draw submission, GPU wait). If `outside` dominates, look at `calls` / `objects` and `render
cpu`; if sim or views grow with enemies, it is script cost. Only numbers from a real GPU count: the VPS runs software GL at about
7 fps. Probes: `tests/perf/` (`fight_breakdown.gd`: a held Hollow Graves fight; main-thread CPU per frame, a knock-out table per system; `tools/godot/profile.py` runs any probe under Godot's script profiler for per-function times), `tests/next/render_probe.gd`; the `tests/next*` suites print per-system timings as `INFO perf:` lines and never assert them (only deterministic counters are checks).
