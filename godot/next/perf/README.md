# godot/next/perf: performance controls + GPU warm-up

`DmNextPerf` (child `Perf` of `DmNextGame`, `game.perf`): the Settings panel's graphics, fps cap and auto-resolution settings.
`apply(settings)` runs in `start()` (`opts.settings`, default High / uncapped / auto_res on) and on every Settings change (`DmNextUiHost`).
- `graphics` low: no moon shadows, no bloom, 3 prop lights (8 on High), halved weather, `Vfx.quality = "low"`.
- Moon shadow casters: `DmCasterBudget` every 0.5 s keeps the nearest 12 enemies (8 with 32+ alive) casting on High (Medium 8/6, Ultra 20/14, Low none); the hero, thralls and bosses always cast.
- `fps`: `Engine.max_fps` (0 = uncapped; the governor judges against the cap, or 60 for Max).
- `auto_res`: `DmResolutionGovernor`  on the root viewport's `scaling_3d_scale`; `pace(dt)` per frame once `ready_` (real renderer only),
  `hold()` on every area entry. A graphics / fps / auto_res change restarts it at 1.0 and holds.
- Prop culling cells (12 m), shadow range (32 m), streaming and light LOD are `DmWorldBuilder`'s, driven every frame by `DmNextWorld.update`.

`DmNextWarmup.run(game)` (end of `start()`, under `DmWarmup`'s cover; default on with a real renderer, `opts.warmup` forces it): threaded loads of every model +
Binbun scene; one body per distinct slug of every enemy kind / thrall / legion / boss (opaque, elite emissive, mid-fade, thrall gear + spectral variants), every Binbun
effect, every decal / flash layer, the enemy and boss telegraph shapes; then the tour of all 13 areas (the stage travels with the camera; per stop: lit, with every point
light hidden = Godot's separate "no omni light" variant, and with the shared flash light on). Everything is freed afterwards; `DmNextWarmup.last_ms` holds the time.
Test hooks: `DmModels.cold_loads`, `DmFxBinbun.cold_loads` count first loads from disk (0 after a warm-up).
Tests: `tests/next_perfctl/run.gd`. Rendered probe: `tests/next_perfctl/entry_probe.gd` (header has the command).

## Reading the F3 overlay

The F3 overlay splits the frame: `tick` is the game tick by system, `fx` the `Vfx` autoload, `ui` the HUD and counsel, `outside`
the rest (engine animation, culling, draw submission, GPU wait). If `outside` dominates, look at `calls` / `objects` and `render
cpu`; if sim or views grow with enemies, it is script cost. Only numbers from a real GPU count: the VPS runs software GL at about
7 fps. Probes: `tests/perf/`, `tests/next/render_probe.gd`; per-system budgets are asserted in the `tests/next*` suites.
