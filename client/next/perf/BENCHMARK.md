# The benchmark

The in-game benchmark: the same fight on every PC, how to run it, the fight's rules and where a run goes. Reading its report and what runs have measured: [BENCHMARK-REPORT.md](BENCHMARK-REPORT.md); the other performance controls: [README.md](README.md).

The in-game benchmark (`next/perf/README.md`): one held fight in each of the nine combat rooms with the four necromancers or the Reaper, so the Full Party fight can be measured on any PC, room by room. The launch was checked with it against the old game (DECISIONS B50).

## The code, the setup and the results

`DmBenchmark` (`dm_benchmark.gd`, setup window `dm_benchmark_setup.gd`, UI `dm_benchmark_screen.gd`, run history + upload `dm_bench_history.gd`, shared fight setup
`dm_bench_fight.gd`, the frame split `dm_frame_split.gd`). Run it from the **Benchmark** button (bottom right of the character select screen: the setup
window, then the run; Back returns there) or `godot -- --benchmark`. The launch options, the rooms, the classes, the sizes and the fight's rules (the fixed seed, the god-mode hero on Easy auto combat, the same toughness for every enemy in every room) are
below; the report's budget section, the crowd's cost counters, the headless frame pad and the world dressing's cost are in [BENCHMARK-REPORT.md](BENCHMARK-REPORT.md).
- Setup (`configure`, remembered per PC in `user://benchmarks/setup.json`): size Light 15 enemies / 10 thralls, Standard 30 / 20, Heavy 60 / 30, Full Party 72 / 32 and the room's boss (`SIZES`; the director's body limit is raised to 100 so a Heavy or Full Party fight's corpses
  don't stall spawning). `STANDARD` (Bell Sanctum, Gravecaller, Standard, Full) is the setup that compares PCs; any other is labelled custom in the window, the report and the history.
- **Full Party** is the biggest fight the game can make, the one the performance budgets are measured on (DECISIONS B71); the report has a Boss line (woken / defeated, share of the measured window awake) and the upload carries `boss_awake_pct`.
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
  and frame time each part costs on that PC. Visibility only, restored after each sample. What the rows count: client/next/perf/DRAW-BUDGET.md.
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
- Test: `client/tests/benchmark.gd`, `benchmark_rooms.gd`, `benchmark_classes.gd`, `benchmark_launch.gd` and `benchmark_flags.gd` (five suites sharing `benchmark_base.gd`; short runs: the Standard setup, a custom one and a Full Party fight at its real size; the same enemy health in every room, history, the upload queue against fake servers, the setup window and launch arguments; deterministic checks only).

## Running it

```
bash client/tools/bake_crowd.sh                                                                                                    # once: the crowd models the fight draws (with none baked the crowd does no view work: about 0.6 ms a frame cheaper, and the report says so)
nice -n 10 /home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client -- --benchmark --bench-room=graves --bench-size=full_party --bench-class=2   # the VPS processor test; the report is in the log
nice -n 10 /home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client -- --benchmark --bench-room=fen --bench-size=full_party --bench-class=11 --bench-length=quick   # any of the nine rooms (graves warren ossuary nave coliseum sanctum cloister pyre fen), any of the five classes (1 2 3 4 11)
/home/ubuntu/tools/godot/godot --path client -- --benchmark --bench-room=graves --bench-size=full_party                              # on a PC: the fight in the window, then the render breakdown
DeathMuffin.exe --main-pack DeathMuffin.pck --windowed -- --benchmark --bench-room=graves --bench-class=2 --bench-size=full_party --bench-length=full --bench-preset=low --bench-dir=<folder> --bench-quit   # the team app's run of a release build
```

- **Launch:** `-- --benchmark` runs it at once on an isolated offline game (no login) and stays on the results screen with a Quit button; a headless run quits by itself once the report is out (`BENCHMARK` lines in the log and
  `user://benchmarks/bench-<datetime>.txt`). From the character select, the **Benchmark** button opens the setup window; Start runs it and Back returns. `--bench-room=`, `--bench-class=`, `--bench-size=light|standard|heavy|full_party` and
  `--bench-length=quick|full` pick the setup (Quick: 6 s warm-up and 20 s measured; Full: 10 s and 30 s, then the render breakdown), `--bench-warm=<s>` / `--bench-measure=<s>` shorten it, `--baked=<dir>` names the baked crowd models.
  **The rooms** are the nine combat areas (`DmBenchmark.ROOMS`: the Hollow Graves, Catacomb Warren, Marrow Ossuary, Drowned Nave, Bone Coliseum, Bell Sanctum, Plague Cloister, Cinder Pyre and Mourning Fen; the Depths is an instance, not a room) and **the classes** the four
  necromancers and the Reaper (`class_indices`, 1 2 3 4 11, the playable disciplines): anything else (`--bench-room=depths`, a greyed-out `--bench-class=5`) is refused with a message that lists what the benchmark has, and exit code 2 (`DmBenchmark.refusal`).
  The Standard setup is the Bell Sanctum, Gravecaller, Standard size, Full; the Full Party fight the budgets are measured on (DECISIONS B71) is a custom setup in the Graves. Only the picked room's area is loaded (`opts.areas`), so the run measures the room, not the world.
  **The team app's flags** (2026-10-19; the app's `bench` job runs the release build with them, server/death-muffin/README.md "Team jobs"; both work in a release build and only together with `--benchmark`):
  `--bench-preset=<low|medium|high|ultra>` is the graphics preset of the run: it replaces the player's setting for this run as if chosen in Settings and is never saved (`DmBenchmark.graphics_preset`, read through
  `DmBenchmark.user_settings`, which puts it on loan with `DmSettings.session_set`; the report's "Graphics preset" line and the queued run say it). A value that is not a preset is refused like an unknown room, with a message
  that lists the presets, and exit code 2. `--bench-quit` makes a windowed run quit by itself once its run is recorded (a headless run always does): exit code 0 when the run is the last entry of the queue, 1 when it was cancelled (it is
  queued too, flagged `cancelled`, so the caller must not send it) or the queue could not take it (`DmBenchmarkScreen.exit_code`). With `--bench-dir=<folder>` the run is a trial that sends nothing, and the payload the app uploads is the
  last entry of `<folder>/pending.json` (`DmBenchHistory.record`: the body `DmApi.post_benchmark` sends). `tests/benchmark.gd` (the exit codes, the loan) and `tests/benchmark_flags.gd` (a real launch) cover both.
- **Where the files go:** the report, the history, the queue of runs to send and the last setup are in `DmBenchmark.dir` (`user://benchmarks`); `--bench-dir=<dir>` keeps a run's in a folder of its own, and a run that has one is a trial that sends nothing.

## The fight

- **The fight:** the fixed seed 20261011, a god-mode level 60 hero of the picked class on Easy auto combat holding his ground at the walkable point nearest the room's centre that a path joins to its doorway (the Sanctum's centre is a cut-off dais), no elites, every enemy on the health and damage of the Bell Sanctum
  roster's average (272.9 hp, 10.8 damage: `DmBenchmark.STATS_ROOM`, the same in every room), waves brought in to 6 to 14 m, the count topped up and trimmed every 0.25 s, and for Full Party 72 enemies, 32 thralls and the room's boss held awake
  (the one that sleeps in that room, `DmBenchFight.boss_of`: the Gravedigger King in the Graves, the Bone Abbess in the Ossuary, the Drowned Congregation in the Nave, the Bell-Sworn Prelate in the Sanctum, the Plague Saint in the Cloister, the Cinder Regent in the Pyre
  and the Mire Mother in the Fen; woken through the real summon, again after each defeat; the Warren and the Coliseum have none and run without, and the Setup line says so). The director spawns through `DmCoreHost.spawn_enemy`, `trim` removes the farthest extras with `remove_enemy` (no death, no corpse, no reward), the thralls are raised
  straight into the core without the cap, and every count is read from the core. `DmBenchFight` holds these rules.
- **Not in the fight:** the guests' hero bodies.

## Sending a run

- **Sends:** the run's backend is the in-memory mock. A finished run is queued in `pending.json` (`DmBenchmark.dir`) and sent to the **live server's** benchmark history (`DmApi.post_benchmark`; `net/dm_config.gd` allows no other address): from the character select with the logged-in api, from `--benchmark` with a
  release build's saved login; debug builds, `--dev-offline`, a run with its own `--bench-dir=` and tests never send (the run waits in the queue, and goes out the next time a logged-in online session has an api). The one door a run leaves by is
  `DmBenchHistory.flush`, and from a script run (every test is one) it refuses a real transport. `tests/benchmark_classes.gd` pins it: it points `DmBenchmark.dir` at a folder of its own (with its baked models, removed at the end), so another run's history,
  queue or setup can neither change a check nor be sent by it, and its uploads go to a mock that answers as the server's API.
