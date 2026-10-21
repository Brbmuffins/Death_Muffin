# Threads

The rule for work off the main thread, and what runs there. The combat core's host: `client/core/dm_core_host.gd`; the guard: `client/core/dm_thread_guard.gd`.

A worker computes data and hands it back; whatever touches the scene tree, a node, a signal or a Godot object that is not thread-safe happens on the main thread, after the worker has finished. The places that take a worker's result call
`DmThreadGuard.assert_main` first (a violation is an error in the log and a count the suites check is 0: `tests/depths.gd`). `tests/threads.gd` lists what starts work off the main thread and fails on anything new until it has been read and added here; the C++ core starts no thread, lock or atomic.

| what | thread | touches | result |
|---|---|---|---|
| the Depths' floor generator (`DmDepths._generate`) | a `WorkerThreadPool` task | content (read only once `DmDbWarm` has run) and its own arrays | polled on the physics frame with `is_task_completed`, joined, the Dictionary returned to the controller |
| the Depths' navmesh bake (`DmDepthsGround.prepare`) | the navigation server's pool task (`bake_from_source_geometry_data_async`) | the source geometry and the `NavigationMesh` handed to it, which the main thread leaves alone until `is_baking_navigation_mesh` is false; the server emits `changed` in its own main-thread `sync` | the mesh goes on the region (`show`) on the main thread; a bake that does not finish in 20 s is made again on the main thread on a fresh mesh |
| the Gear Atlas' verdicts (`DmUiPanelsA._atlas_*`) | a `WorkerThreadPool` task | a deep copy of the stat context, a fresh map of what is owned, and the static tables the first main-thread pass filled (`tests/threads.gd` checks a worker writes none of them) | joined in `_atlas_data` or `tick` before the result is read |
| a legendary body's prefetch (`DmGearModels.prefetch`), the sample bank (`DmSampleBank`, twelve in flight), the warm-up's models (`DmNextWarmup`, not headless), the release check `--boot-check --quit-while-loading` (`DmMain`: asks for the warm-up's models, then quits with them in flight) | `ResourceLoader.load_threaded_request` | resources only, no node | `load_threaded_get`, or `load` from the cache, on the main thread |
| the mixer | the audio driver's thread (the Dummy driver in a headless run) | the bus layout and every playing stream, under the audio lock | n/a |

**Data the workers read.** `DmDbWarm.all()` (`DmNextGame.start`, in loading) reads every dataset and projection of `DmDb` once, so its cache never changes again: a Godot Dictionary is not safe to read on one thread while another inserts, and a first use of a dataset
is an insert. About 100 files, 4.6 MB; +60 ms in loading (3.37 s without, 3.43 s with, three runs each alternating on the shared VPS, spread +-0.25 s). The Depths' floor generator calls `DmDbWarm.all()` (a hundred lookups when warm) and `DmSimData.ensure()` before it starts.

**The mixer.** `AudioServer.add_bus` and `set_bus_send` edit the bus list, the name map and a bus's send without taking the audio lock (Godot 4.7.2 `servers/audio/audio_server.cpp`), while the mixer thread reads all three in every mix step (`bus_map[bus->send]`). An edit that lands
in the middle of a step can crash the mixer thread (the one crash log with frames, 2026-10-07: the Dummy driver's loop, then the step's lookup of a bus's send in the name map). The director makes about 55 buses at start, while the mixer already runs (`AudioDirector` is an autoload), and changes a voice's send as sounds play. Its two helpers `_add_bus` and `_set_bus_send` hold
`AudioServer.lock()` around an edit (the lock is recursive: `set_bus_name` and `add_bus_effect` take it themselves); nothing else in the client edits the layout (`tests/threads.gd`).

**Reading a crash.** A crash on any thread but the main one prints, just before Godot's `handle_crash: Program crashed with signal N` and its C++ frames, `ERROR: /root: The caller thread can't call the function propagate_notification()`. That is not code touching the tree: the crash
handler tells the main loop, the scene tree hands the notification to `/root`, and the call is refused off the main thread. Then the process aborts (exit 134, SIGABRT) whatever the signal was. (`OS.crash()` in a `WorkerThreadPool` task prints exactly this.) The signal and the frames are the
crash: `start_thread` at the bottom is a pool, loader or driver thread, and a GDScript backtrace under the message names the script that thread was running, if any. The official binary has no symbols; the frames can
be told apart by what they call (a function that takes the audio mutex, calls `clock_gettime` before and after, then `delay_usec` is the Dummy driver's loop).
