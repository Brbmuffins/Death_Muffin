class_name DmMain
extends Node
## Game entry (main scene) of the rebuilt client. Boot -> DmFrontFlow (login / discipline select) against the TEST
## server (DmConfig.API_BASE: DECISIONS B38, the live server is never touched before launch day) -> DmNextGame with the chosen character, its bag and its progression.
## Only the four necromancer disciplines and the Reaper are playable (DmCharacterBuild.is_playable); a character of another discipline is sent to the discipline
## switch by the front flow.
## Launch args (after `--`): none needed. Testing only (editor / debug builds; a release export ignores them): `--dev-offline` = local accounts + progress in DEV_OFFLINE_DB
## (DmMockBackend: no network at all); `--dev-offline --class=N` skips the front flow (test account `tester`) and enters directly, with `--seed=N`, `--no-waves` and `--baked=<dir>`
## as the dev entry (dev/dm_dev_entry.tscn, which stays the way to a crowd or a screenshot); `--world-demo` is an alias of `--dev-offline --class=2`.
## `--boot-smoke`: reach the first screen, print "BOOT OK <screen>" and quit (the test channel's publish check).
## `--boot-check` (release-safe: it only quits; the team app's `install` step runs the release build with it): reach the first screen, print `BOOT OK <ms>` (ms since the engine started) and quit with exit code 0; no first
## screen within 60 s prints `BOOT FAIL ...` and quits with exit code 1 (`_boot_check`). With `--quit-while-loading` (also release-safe, and read only with `--boot-check`) it quits with the art pack's models still loading on the
## worker threads (the case that crashed the old game on 4-core PCs), after `QUIT-WHILE-LOADING <n> of <m> loads in flight`; the team app's `quit-loading` step checks the exit code 0 and that DmCrashWatch left no crash report.
## `--qa` / `--shot-plan=<plan.json>` (with `--shots=<dir>`, `--seconds=N`; dev-offline runs only): the QA tools beside the game, the scripted fight or the shot plan of a proposal (`start_qa`, client/README.md "Screenshots for proposals").
## `--clip-plan=<plan.json> --clips=<dir>` (the same QA runs, engine started `--fixed-fps 30`): short video clips of a rite in use, 30 frames per game second as `<name>.mjpeg` (DmQaClips, client/README.md "Clips and tune").
## `--tune=<data.json>` (only where the QA tools start, `qa_tune`): data overrides for this run, merged into the game's data before anything reads it (DmQaTune); an unknown file, key or type is refused with a printed line and exit code 2.
## `--preset=<low|medium|high|ultra>` (only where the QA tools start, `qa_preset`): that graphics preset is in force from the game's start, as if chosen in Settings, and is never saved to the player's settings
## (a team PC's screenshots of a proposal on Low and Ultra); an unknown value is ignored with a printed warning. `--ui-scale=<0.8 to 1.25>` (`qa_ui_scale`) is Settings' Interface size for the run the same way.
## `--stutter --stutter-out=<abs dir>` and `--soak[=<minutes>] --soak-out=<abs dir>` (QA runs only, `qa_scenario`; they write `<dir>/stutter.json` and `<dir>/soak.json`): the release checks' scenarios, each on isolated offline games of its own
## with no front flow (DmQaStutter: every rite of each playable discipline cast once, the worst frame and the pipeline compilations of each; DmQaSoak: auto combat in the Graves with waves for that long, a row a minute and the growth), client/README.md "Release checks".
## A QA run also never takes the keyboard or the mouse from the person at the PC (`quiet_window`: no focus, mouse events pass through), so a team PC can run it while its owner works.
## `--benchmark`: runs the in-game benchmark straight away on an isolated offline game (DmBenchmark, no login; `--bench-room=`, `--bench-class=`, `--bench-size=`,
## `--bench-length=` pick the setup, default the Standard one, `--bench-warm=` / `--bench-measure=` shorten it, `--baked=<dir>` names the baked crowd models) and stays on the
## results screen with a Quit button (a headless run quits by itself). A room or class the benchmark does not list is refused with a message and exit code 2. Release builds then
## send the run, to the game's server, with the saved login, if any, unless `--bench-dir=<dir>` keeps the run's files (report, history, queue, last setup) in a folder of its own: a trial,
## which sends nothing. The character select screen's Benchmark button opens the setup window (DmBenchmarkSetup) first.
## Two more flags, release-safe and only read together with `--benchmark` (the team app's `bench` job runs a release build with them): `--bench-preset=<low|medium|high|ultra>` is the graphics
## preset of the run (applied as Settings would, on loan for the run: DmBenchmark.user_settings, `session_set`, so the player's file is never written; an unknown value is refused with a message
## and exit code 2, like an unknown room) and `--bench-quit` makes a windowed run quit by itself once its run is recorded (a headless run always does): exit code 0 when the run is in the queue
## (`pending.json` of `--bench-dir`, its last entry), 1 when it was cancelled or could not be recorded (DmBenchmarkScreen.exit_code).
## `start_opts` (set before add_child; tests) are merged over DmNextGame.start's options.
##
## Co-op: the party's `join_ready` hands the solo game over to a guest game on the same lobby socket, and a guest whose session ended (or whose join failed) is
## put back in its own world with the reason on screen (client/README.md "Co-op on the core").
## The panels' hand-overs: Log out (final save, the token dropped, the login screen), Switch character (final save, the select screen with the same token) and a
## discipline change from the class panel (final save, the game restarts with the changed character).
## The automatic crash report (since launch day, 2026-10-18): a release build's lock (DmCrashWatch) still there at the next start sends the last run's crash
## as a bug report once the player is in an online world (`_send_crash_report`).
## The play report (ROADMAP Phase 1; client/next/perf/README.md "Play reports"): a release build's online session is counted by one DmPlayReport (`report`, a child of this node, so a party
## hand-over or a discipline change that swaps the game scene keeps it) from the first ready game scene until Log out, Switch character or quit, then queued in user:// and sent with the
## logged-in api right away on Log out and quit (at most 2 s), else at the character select and when a session starts (DmPlayReportQueue). Never from a debug build, a script run, the dev-offline backend or the benchmark (`plays_report`).

const DEV_OFFLINE_DB := "user://dm_dev_offline_db.json"    ## --dev-offline testing backend (the same file the dev entry uses)
const BOOT_CHECK_MS := 60000                                ## `--boot-check` fails when no first screen is up after this long
const QA_SOAK_MINUTES := 30.0                               ## what a bare `--soak` runs for

var mode := ""              ## "online" | "dev_offline" | "test" (injected api, local wording) | "benchmark" (`--benchmark`); "" = decided from the launch args in _ready
var flow: DmFrontFlow
var slice: DmNextGame
var api: DmApi              ## set before add_child (tests) to inject a backend; otherwise built from the launch args
var persist_token := true
var start_opts := {}
var bench_dir := ""         ## `--benchmark --bench-dir=<dir>`: the run's files are kept there and nothing is sent
var _mock: DmMockBackend
var _transport: DmHttpTransport
var _idle_cam: Camera3D
var _build := {}                    ## the character's bag and progression of the last world entry (load_build): a party hand-over starts the next game with them
var _transit_lobby: DmLobbyClient   ## the lobby socket a join was made on, polled here while the solo game is swapped for the guest game
var _party_busy := false            ## a join / return is in progress (one at a time)
var _crash_checked := false         ## the pending crash report (DmCrashWatch) was tried this run
var plays_report := false           ## this session is counted for a play report (decided in _ready by DmPlayReportQueue.records; a test sets it before add_child to try the wiring)
var report: DmPlayReport            ## the session in progress (null until the first ready game scene)


func _ready() -> void:
	get_tree().auto_accept_quit = false
	DmCrashWatch.begin(DmBuild.version())   # a release build's lock: still there at the next start = this run crashed
	# The combat core writes where it crashed into this note while crashing (native/README.md "Crash notes"); the next start's report carries it.
	DmCore.arm_crash_note(ProjectSettings.globalize_path(DmCrashWatch.CORE_NOTE), DmBuild.version())
	# The window title players see. config/name in project.godot stays as it is: Godot names the user:// folder after it (the saved
	# login, settings, tips), so renaming it would sign every player out and reset their settings.
	get_window().title = "Death Muffin"
	# Physics interpolation (project setting) is opt-in per body: everything is OFF by default (effects, cameras, anything placed from
	# _process), and only what is moved in _physics_process turns itself ON (DmSessionBody on the host, the core's heroes).
	get_tree().root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# The Vfx autoload reads the current 3D camera every frame: keep one alive behind the login screens (the world camera takes over).
	var idle_cam := Camera3D.new()
	idle_cam.name = "IdleCamera"
	add_child(idle_cam)
	idle_cam.current = true
	_idle_cam = idle_cam
	add_child(DmPerfOverlay.new())   # F3 / ?fps overlay, as the web
	var args := OS.get_cmdline_user_args()
	if "--benchmark" in args:
		mode = "benchmark"
		var why := DmBenchmark.refusal(bench_wanted_from_args(args))
		if why != "":
			printerr("BENCHMARK refused: " + why)
			get_tree().quit(2)
			return
		var launch := DmLaunchArgs.options(args)
		bench_dir = String(launch.get("bench_dir", ""))
		if bench_dir != "":
			DmBenchmark.dir = bench_dir
		_run_benchmark(true, bench_setup_from_args(args), _arg_float(args, "--bench-warm=", -1.0), _arg_float(args, "--bench-measure=", -1.0), String(launch.get("baked", "")),
			String(bench_wanted_from_args(args).get("preset", "")), "--bench-quit" in args)
		return
	if mode == "":
		mode = mode_for(args)
	plays_report = plays_report or DmPlayReportQueue.records(mode, OS.is_debug_build(), OS.get_cmdline_args())
	if plays_report:
		DmPlayReportQueue.recover()   # a session the last run left unfinished (a crash) is queued with endReason "crash"
	if mode == "dev_offline":
		var o := DmLaunchArgs.options(args)
		if o.has("seed"):
			start_opts["seed"] = o["seed"]
		if o.has("baked"):
			start_opts["baked_dir"] = o["baked"]
		if bool(o["no_waves"]):
			start_opts["waves"] = false
	if qa_wanted(args, mode):
		var tune := qa_tune(args, mode)
		if tune != "":
			var applied := DmQaTune.apply_file(tune)   # before the game scene (and the core's data) is built, so every number is read tuned
			for line in applied["lines"]:
				print(line)
			if not applied["ok"]:
				get_tree().quit(2)
				return
		quiet_window(get_window())
		print("QA-SHOTS window: takes no focus and passes the mouse through (asked of the %s display)" % DisplayServer.get_name())
		var scenario := qa_scenario(args, mode)
		if scenario != "":
			_run_qa_scenario(scenario, args)   # its own games, no front flow, and the run ends with its exit code
			return
		start_qa()
		var preset := qa_preset(args, mode)
		if preset != "":
			start_opts["qa_preset"] = preset   # DmNextGame applies it before the world is built; DmSettings keeps it out of the player's file
		var ui_scale := qa_ui_scale(args, mode)
		if ui_scale > 0.0:
			start_opts["qa_ui_scale"] = ui_scale   # the same, for Settings' Interface size
	if api != null:
		pass   # injected (tests)
	elif mode == "dev_offline":
		_mock = DmOffline.make_mock(DEV_OFFLINE_DB)
		api = DmOffline.make_api(_mock)
	else:
		_transport = DmHttpTransport.new()
		add_child(_transport)
		api = DmApi.new(_transport.request_callable())
		api.slot_decorator = Callable(DmAffixes, "decorate_slots")
	var quick := quick_start_class(args)
	if mode != "online" and quick >= 0 and not boot_check(args):
		await _dev_quick_start(quick)
		return
	_start_flow()
	if OS.is_debug_build() and "--boot-smoke" in args:
		_boot_smoke()
	if boot_check(args):
		_boot_check("--quit-while-loading" in args)


## Testing (`--boot-smoke`, debug builds): the test channel's publish boots an exported copy and waits for this line, so a build that cannot reach its
## first screen (2026-10-16: a boot script naming a class the export leaves out stopped every test build on a grey screen) is never published. It also
## prints how many crowd models the export finds (2026-10-17: none were found, and the enemies and thralls were invisible).
func _boot_smoke() -> void:
	var end := Time.get_ticks_msec() + 60000
	while (flow == null or flow.current_name == "") and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	print("CROWD %d" % CrowdView.baked_models().size())   # the crowd's baked models as the export sees them (smoke-rebuild.sh compares)
	print("BOOT OK %s" % flow.current_name if flow != null and flow.current_name != "" else "BOOT STUCK")
	get_tree().quit(0 if flow != null and flow.current_name != "" else 1)


## `--boot-check`, in release builds too (the team app's `install` and `quit-loading` steps run the release exe with it): it only quits. Waits for the first screen (the login, or the character select of a saved login) for at most 60 s,
## prints `BOOT OK <ms>` (ms since the engine started, the art pack's mount included) and quits with exit code 0; no screen in time prints `BOOT FAIL` and quits with exit code 1. `quit_loading`
## (`--quit-while-loading`): it first asks the worker threads for the art pack's models (the loads the warm-up makes, DmWarmup) and quits with them in flight, prints how many were (a headless run has no renderer to load for: none).
func _boot_check(quit_loading: bool) -> void:
	var end := Time.get_ticks_msec() + BOOT_CHECK_MS
	while (flow == null or flow.current_name == "") and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	if flow == null or flow.current_name == "":
		print("BOOT FAIL no first screen in %d s" % (BOOT_CHECK_MS / 1000))
		get_tree().quit(1)
		return
	print("BOOT OK %d" % Time.get_ticks_msec())
	print("BOOT screen %s" % flow.current_name)
	if quit_loading:
		var paths: Array = DmWarmup._model_paths() if DisplayServer.get_name() != "headless" else []
		var asked := 0
		for p: String in paths:
			if ResourceLoader.load_threaded_request(p, "", true) == OK:
				asked += 1
		var flying := 0
		for p: String in paths:
			if ResourceLoader.load_threaded_get_status(p) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				flying += 1
		print("QUIT-WHILE-LOADING %d of %d loads in flight" % [flying, asked])
	get_tree().quit(0)


## Testing: the class a dev quick start enters with (`--class=N`; `--world-demo` = class 2), -1 = no quick start (the front flow runs).
static func quick_start_class(args: PackedStringArray) -> int:
	for a in args:
		if a.begins_with("--class="):
			return int(a.substr(8))
	return 2 if "--world-demo" in args else -1


## The mode a launch gets from its user args: online unless a testing flag asks for the local dev backend. Release exports (the players'
## client) never honour the testing flags (owner 2026-10-13): the local backend is for the editor binary and the test suites only.
static func mode_for(args: PackedStringArray, debug_build: bool = OS.is_debug_build()) -> String:
	if not debug_build:
		return "online"
	return "dev_offline" if ("--dev-offline" in args or "--world-demo" in args) else "online"


## Testing: whether the QA tools start (`--qa`, `--shot-plan=<plan.json>` or `--clip-plan=<plan.json>`): on the local dev backend of a debug build only, as `mode_for` has it, so a release export never starts them.
static func qa_wanted(args: PackedStringArray, mode_: String, debug_build: bool = OS.is_debug_build()) -> bool:
	if not debug_build or mode_ != "dev_offline":
		return false
	for a in args:
		if a == "--qa" or a.begins_with("--shot-plan=") or a.begins_with("--clip-plan=") or a == "--stutter" or a == "--soak" or a.begins_with("--soak="):
			return true
	return false


## Release-safe: whether the launch is a boot check (`--boot-check`). It only quits (`_boot_check`), so a release build honours it, unlike every QA flag.
static func boot_check(args: PackedStringArray) -> bool:
	return "--boot-check" in args


## Testing: which release-check scenario a QA run asks for: "stutter" (`--stutter`), "soak" (`--soak` or `--soak=<minutes>`), "" for none. Only where the QA tools start (`qa_wanted`); `--stutter` wins over `--soak`.
static func qa_scenario(args: PackedStringArray, mode_: String, debug_build: bool = OS.is_debug_build()) -> String:
	if not qa_wanted(args, mode_, debug_build):
		return ""
	if "--stutter" in args:
		return "stutter"
	for a in args:
		if a == "--soak" or a.begins_with("--soak="):
			return "soak"
	return ""


## Testing: the minutes `--soak=<minutes>` asks for (30 for a bare `--soak` or a value that is no positive number).
static func qa_soak_minutes(args: PackedStringArray) -> float:
	for a in args:
		if a.begins_with("--soak=") and a.substr(7).is_valid_float() and float(a.substr(7)) > 0.0:
			return float(a.substr(7))
	return QA_SOAK_MINUTES


## Testing: the file a QA scenario writes its results to: `<dir>/<kind>.json` for `--<kind>-out=<abs dir>` (`kind` is "stutter" or "soak"), "" for none.
static func qa_results(args: PackedStringArray, kind: String) -> String:
	var prefix := "--%s-out=" % kind
	for a in args:
		if a.begins_with(prefix) and a.length() > prefix.length():
			return a.substr(prefix.length()).path_join("%s.json" % kind)
	return ""


## Testing: the data file a QA run asks for with `--tune=<abs json>` (DmQaTune), "" for none. Honoured only where the QA tools start (`qa_wanted`), so a release export, an online start and a launch without
## the QA flags ignore it whatever the line says.
static func qa_tune(args: PackedStringArray, mode_: String, debug_build: bool = OS.is_debug_build()) -> String:
	if not qa_wanted(args, mode_, debug_build):
		return ""
	for a in args:
		if a.begins_with("--tune="):
			return a.substr(7)
	return ""


## Testing: a QA run never takes the keyboard or the mouse from the person at the PC (the team app runs it on a team member's own computer, while they work): the main window takes no
## focus (DisplayServer.WINDOW_FLAG_NO_FOCUS, a Window's `unfocusable`) and lets mouse events through to what is under it (WINDOW_FLAG_MOUSE_PASSTHROUGH, `mouse_passthrough`). Called only where the QA tools start
## (`qa_wanted`), so a player's window is never touched. The shot plan opens windows through the HUD's own calls and fakes its hover (`DmTip.test_mouse`), so it needs no real mouse. A headless run has no window to configure:
## only the call path can be tested there (tests/qa_shots.gd).
static func quiet_window(win: Window) -> void:
	if win == null:
		return
	win.unfocusable = true
	win.mouse_passthrough = true


## Testing: the graphics preset a QA run asks for with `--preset=<low|medium|high|ultra>`, "" for none. Honoured only where the QA tools start (`qa_wanted`: a debug build on the dev-offline backend), so a release
## export and an online start ignore it whatever the line says. An unknown value is ignored, with a warning line. It is applied before the game scene starts and is never saved (DmSettings.session_set).
static func qa_preset(args: PackedStringArray, mode_: String, debug_build: bool = OS.is_debug_build()) -> String:
	if not qa_wanted(args, mode_, debug_build):
		return ""
	for a in args:
		if a.begins_with("--preset="):
			var id := a.substr(9)
			if id in DmGraphicsPreset.IDS:
				return id
			print("QA-SHOTS warning: --preset=%s ignored (it must be %s); the game keeps the graphics setting it has." % [id, ", ".join(DmGraphicsPreset.IDS)])
			return ""
	return ""


## Testing: Settings' Interface size a QA run asks for with `--ui-scale=<0.8 to 1.25>`, 0.0 for none. Honoured only where the QA tools start, like `--preset=`; a value outside what Settings offers is ignored with a warning.
## It is applied before the game scene starts and is never saved (DmSettings.session_set).
static func qa_ui_scale(args: PackedStringArray, mode_: String, debug_build: bool = OS.is_debug_build()) -> float:
	if not qa_wanted(args, mode_, debug_build):
		return 0.0
	for a in args:
		if a.begins_with("--ui-scale="):
			var v := a.substr(11)
			if v.is_valid_float() and float(v) >= 0.8 and float(v) <= 1.25:
				return float(v)
			print("QA-SHOTS warning: --ui-scale=%s ignored (it must be a number from 0.8 to 1.25); the game keeps the interface size it has." % v)
			return 0.0
	return 0.0


## Testing: the QA driver (main/qa_driver.gd) as the child Driver, which finds the game this boot makes. It is loaded here, by path, and never named: it names most of the game (compiling it took
## every start about 5 s in the old game, which registered it as an autoload stub), so no other start pays for it. The project file registers no autoload for it: `client/project.godot` is an input
## of the art pack's fingerprint.
func start_qa() -> void:
	var d: Node = load("res://main/qa_driver.gd").new()
	d.name = "Driver"
	add_child(d)


## Testing: a release-check scenario (`qa_scenario`) as the child Scenario: it builds isolated offline games of its own (DmBenchFight), writes its results file (`qa_results`) and returns the run's exit code (0 done, 1 not, 2 refused). Loaded by path,
## like the driver, so no other start compiles it. The graphics preset is High unless `--preset=` says another.
func _run_qa_scenario(kind: String, args: PackedStringArray) -> void:
	var node: Node = load("res://main/qa_%s.gd" % kind).new()
	var runner: Variant = node
	node.name = "Scenario"
	node.set("results_file", qa_results(args, kind))
	var preset := qa_preset(args, mode)
	if preset != "":
		node.set("preset", preset)
	if kind == "soak":
		node.set("minutes", qa_soak_minutes(args))
		var cls := quick_start_class(args)
		if cls >= 0:
			node.set("discipline", cls)
	add_child(node)
	var code: int = await runner.run()
	print("QA-%s exit %d" % [kind.to_upper(), code])
	get_tree().quit(code)


## A normal shutdown (window close, quit) saves first (the web's pagehide flush), then quits.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		await save_all()
		get_tree().quit()


## Final save of the game (also the quit path of the tests): the scene's `flush_all` (rewards, Chronicle, progression, bag).
func save_all() -> void:
	_end_report("quit")   # first, and only files, so the final numbers never wait on the network
	if slice != null and slice.ready_:
		var s := slice
		slice = null
		await s.flush_all()
	await _send_play_reports_now(2000)   # the report goes out before the game closes (what does not make it in time goes at the next start)


func _start_flow(switching_character: bool = false) -> void:
	flow = DmFrontFlow.new(api, mode != "online", mode != "online")
	flow.persist_token = persist_token
	flow.online_gate = mode == "online"   # the test channel's manifest online switch (DmOnlineGate; the test build is open to the team's accounts)
	flow.name = "Front"
	flow.enter_world.connect(_enter_world)
	flow.benchmark_requested.connect(_open_benchmark_setup)
	add_child(flow)
	_flush_play_reports()   # (not awaited) the character select, or the login screen with a kept login: reports of earlier sessions go out now
	if switching_character:
		flow.switch_character()
	else:
		flow.start()


## Shortened benchmark for smoke runs: `--bench-warm=<s>` / `--bench-measure=<s>`.
static func _arg_float(args: PackedStringArray, prefix: String, d: float) -> float:
	for a in args:
		if a.begins_with(prefix):
			return maxf(1.0, float(a.substr(prefix.length())))
	return d


## What a `--benchmark` launch asked for, as given (`--bench-room=graves --bench-class=2 --bench-size=full_party --bench-length=quick --bench-preset=low`): the keys that were named
## (`discipline` for the class; `preset` is the graphics preset of the run, not part of the setup).
static func bench_wanted_from_args(args: PackedStringArray) -> Dictionary:
	var want := {}
	for a in args:
		for k in ["room", "class", "size", "length", "preset"]:
			var prefix := "--bench-%s=" % k
			if a.begins_with(prefix):
				want["discipline" if k == "class" else k] = int(a.substr(prefix.length())) if k == "class" else a.substr(prefix.length())
	return want


## The benchmark setup a `--benchmark` launch asks for (what is not named, or not a setup, is the Standard setup's).
static func bench_setup_from_args(args: PackedStringArray) -> Dictionary:
	return DmBenchmark.normalize_setup(bench_wanted_from_args(args))


## The character select's Benchmark button: the setup window over the select screen; Start runs the benchmark with the pick.
func _open_benchmark_setup() -> void:
	var w := DmBenchmarkSetup.new()
	var top := CanvasLayer.new()
	top.layer = 95
	w.closed.connect(top.queue_free)
	w.start.connect(func(setup: Dictionary) -> void:
		top.queue_free()
		_run_benchmark(false, setup))
	top.add_child(w)
	add_child(top)


## The api the benchmark sends its runs with: the logged-in online one from the character select (the live server's: the transport refuses any other address, net/dm_config.gd);
## for `--benchmark` (no login screen) a release build's saved login. null (dev-offline, tests, debug builds, a trial with its own `--bench-dir=`, never logged in) = the run waits in
## DmBenchHistory's queue.
func _bench_upload_api() -> DmApi:
	if mode == "online" and api != null:
		return api
	if mode != "benchmark" or bench_dir != "" or OS.is_debug_build() or not FileAccess.file_exists(DmApi.TOKEN_FILE):
		return null
	if _transport == null:
		_transport = DmHttpTransport.new()
		add_child(_transport)
	var a := DmApi.new(_transport.request_callable())
	a.persist_token = true   # reads the saved login (get_token); nothing else is written
	return a


## The benchmark over whatever is on screen: from the character select (the front flow is hidden meanwhile, Back returns to it) or as the whole
## session (`--benchmark`, Quit button). It builds its own mock-backed game; `api` and the player's characters are never used.
func _run_benchmark(quit_on_close: bool, setup: Dictionary = DmBenchmark.STANDARD, warm_s: float = -1.0, measure_s: float = -1.0, baked_dir := "", preset := "", auto_quit := false) -> void:
	if flow != null:
		flow.visible = false
	var s := DmBenchmarkScreen.new()
	s.quit_on_close = quit_on_close
	s.auto_quit = auto_quit
	s.graphics_preset = preset
	s.setup = setup
	s.warm_s = warm_s
	s.measure_s = measure_s
	s.baked_dir = baked_dir
	s.api = _bench_upload_api()
	var top := CanvasLayer.new()
	top.layer = 95   # above the fight's HUD (10) and loading cover (90), under the F3 overlay (100): the screen takes every click
	s.closed.connect(func() -> void:
		top.queue_free()
		_idle_cam.current = true   # the fight's camera is gone
		if flow != null:
			flow.visible = true)
	top.add_child(s)
	add_child(top)


## Back to the login screen with the reason on it (the token is dropped, as the front flow does when a character cannot be resumed).
func _back_to_login(reason: String) -> void:
	_end_report("logout")   # (a session that was counting before a restart or a hand-over that could not go on)
	api.set_token("")
	_start_flow()
	if flow.current is DmLoginScreen:
		flow.current.show_notice(DmFrontUi.capitalize_first(reason))


## Testing: `-- --dev-offline --class=N` (or `--world-demo`, class 2) skips the front flow and enters the game as `tester` on the dev-offline backend.
func _dev_quick_start(cls: int) -> void:
	var r := await api.register("tester", "t@example.com", "pw1234")
	if not r.ok:
		r = await api.login("tester", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(cls)
	await _enter_world(c.data, api)


## The account name the session token carries (web tokenUsername): "offline:<name>" or a JWT whose payload has `username`.
static func token_username(token: String) -> String:
	if token.begins_with("offline:"):
		return token.substr(8)
	var parts := token.split(".")
	if parts.size() >= 2:
		var b64 := String(parts[1]).replace("-", "+").replace("_", "/")
		while b64.length() % 4 != 0:
			b64 += "="
		var raw := Marshalls.base64_to_raw(b64)
		var j: Variant = JSON.parse_string(raw.get_string_from_utf8())
		if j is Dictionary and j.get("username") is String:
			return j["username"]
	return "You"


## What a character's build is made from, read from the server as the HUD's bag load and DmProgressSync.connect_server read it: the bag's rows (worn gear,
## set bonuses) and the progression (damage and legion tier, boons, vows). Reads only: nothing is written, imported or created. {ok, error, slots, local}. An older
## server without the progress route (404) plays with the base numbers; any other failure is the server's own player-readable error.
static func load_build(api_: DmApi, character: Dictionary) -> Dictionary:
	var id := int(character.get("id", 0))
	var bag: DmResult = await api_.get_inventory(id)
	if not bag.ok:
		return {"ok": false, "error": bag.error}
	var local := {}
	var np: DmResult = await api_.necro_get(id)
	if np.ok and np.data is Dictionary and np.data.get("progress") is Dictionary:
		var prog := DmProgression.new(character)
		prog.adopt(np.data["progress"])
		local = prog.local
	elif np.status != 404:
		return {"ok": false, "error": np.error}
	return {"ok": true, "error": "", "slots": bag.data, "local": local}


func _enter_world(character: Dictionary, session) -> void:
	api = session
	if mode == "online" and DmBenchHistory.pending_count() > 0:
		DmBenchHistory.flush(api)   # benchmark runs that could not be sent before (no login, no network); not awaited
	_flush_play_reports()
	if flow != null:
		flow.queue_free()
		flow = null
	if not DmCharacterBuild.is_playable(float(character.get("class_index", 0))):
		_start_flow()   # the front flow's resume() offers the discipline switch
		return
	var loading := DmLoadingScreen.acquire(self, "Waking the dead...")
	loading.set_progress(0.05)
	var build := await load_build(api, character)
	if not build["ok"]:
		loading.dismiss()
		_back_to_login(String(build["error"]))
		return
	await _enter_next(character, loading, build)


## DmNextGame behind the same key-art loading screen (it paints before the synchronous world build; it fades out once the game is ready). A game that refuses to
## start (an api that is not the live server's) is dropped and the login screen says why. `join`: {lobby} starts a guest game on that seated lobby socket (a refused or
## lost join lands the player in their own world again), {notice} is the line the new game shows on arrival.
func _enter_next(character: Dictionary, loading: DmLoadingScreen, build: Dictionary, join: Dictionary = {}) -> void:
	_build = build
	await get_tree().process_frame
	await get_tree().process_frame
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	slice = g
	add_child(g)
	var opts := {"name": token_username(api.get_token()), "hud": true, "slots": build["slots"], "local": build["local"]}
	for k in ["lobby", "notice"]:
		if join.has(k):
			opts[k] = join[k]
	opts.merge(start_opts, true)
	var refused := [""]
	var join_failed := _on_next_join_failed.bind(character, loading)
	if join.has("lobby"):
		opts["host"] = false
		g.start_failed.connect(join_failed, CONNECT_ONE_SHOT)
	else:
		g.start_failed.connect(func(reason: String) -> void: refused[0] = reason)
	await g.start(character, api, opts)
	if is_instance_valid(g) and g.start_failed.is_connected(join_failed):
		g.start_failed.disconnect(join_failed)
	if slice != g:
		return   # a refused guest: the failure handler already swapped the game
	if refused[0] != "":
		slice = null
		g.queue_free()
		loading.dismiss()
		_back_to_login(refused[0])
		return
	_transit_lobby = null
	_attach_report(g)
	if g.ui_host != null:
		g.ui_host.left_world.connect(_on_next_left.bind(true))
		g.ui_host.character_switch.connect(_on_next_switch)
		g.ui_host.world_restart.connect(func(ch: Dictionary) -> void: _on_next_restart(ch))
	g.party.join_ready.connect(_on_next_join_ready)
	g.party.client_ended.connect(_on_next_client_ended.bind(character))
	loading.dismiss()
	_send_crash_report(g, character)


## A normal shutdown (window close, quit, benchmark end) removes the crash lock; a crash never gets here.
func _exit_tree() -> void:
	_end_report("quit")   # (a quit has ended it already in save_all)
	DmCrashWatch.end()


## The game scene is ready: the session's play report counts its frames (a first scene starts the report, a hand-over's next scene continues it).
func _attach_report(g: DmNextGame) -> void:
	if not plays_report or not g.ready_:
		return
	if report == null:
		report = DmPlayReport.new()
		report.name = "PlayReport"
		report.autosave = true
		add_child(report)
		report.begin(DmBuild.version())
	report.attach(g)


## The session is over (`reason`: logout, switch, quit): the report is queued in user:// (files only). A log out and a quit then send it (`_send_play_reports_now`,
## at most 2 s), Switch character at the select screen; whatever is left goes at the next character select or session start.
func _end_report(reason: String) -> void:
	if report == null:
		return
	var rep := report
	report = null
	DmPlayReportQueue.end_session(rep, reason)
	rep.queue_free()


## Sends the queued play reports with the logged-in online api, in the background (DmPlayReportQueue.flush; nothing waits on it).
func _flush_play_reports() -> void:
	if plays_report and api != null and DmPlayReportQueue.pending_count() > 0:
		DmPlayReportQueue.flush(api)


## Sends the queued play reports now and waits for them at most `ms` (a log out drops the token right after, a quit closes the game);
## what has not gone out by then stays queued for the next start.
func _send_play_reports_now(ms: int) -> void:
	if not plays_report or api == null or api.get_token().is_empty() or DmPlayReportQueue.pending_count() == 0:
		return
	DmPlayReportQueue.flush(api)   # not awaited: the wait below bounds it
	var until := Time.get_ticks_msec() + ms
	while DmPlayReportQueue.flushing() and Time.get_ticks_msec() < until:
		await get_tree().process_frame


## Once per run, in an online world: the last run's crash (DmCrashWatch) goes to the devs as a bug report, and the player is told.
func _send_crash_report(g: DmNextGame, character: Dictionary) -> void:
	if _crash_checked or mode != "online" or api == null:
		return
	_crash_checked = true
	var rep := DmCrashWatch.pending_report(int(character.get("id", 0)))
	if rep.is_empty():
		return
	var r: DmResult = await api.send_bug_report(rep)
	if not r.ok:
		return   # kept: tried again next run
	DmCrashWatch.clear()
	if is_instance_valid(g) and g.ui_host != null:
		g.ui_host.game_event.emit("toast", {"text": "The game closed unexpectedly last time. A crash report with your game log was sent to the devs.", "kind": ""})


func _process(_dt: float) -> void:
	if _transit_lobby != null:
		_transit_lobby.poll()


## Party: the lobby seated us in a host's session. The solo game is freed and a guest game starts on the same lobby socket.
func _on_next_join_ready(lobby: DmLobbyClient, _info: Dictionary) -> void:
	if _party_busy or slice == null:
		lobby.leave()
		return
	_party_busy = true
	var character := slice.character
	_transit_lobby = lobby
	await _teardown_next()
	await _enter_next(character, DmLoadingScreen.acquire(self, "Entering the host's world..."), _build, {"lobby": lobby})
	_party_busy = false


## Party: the session we joined is over (left, removed, host gone, connection lost): back to our own world, with the reason on screen.
func _on_next_client_ended(_reason: String, text: String, character: Dictionary) -> void:
	if _party_busy or slice == null:
		return
	_party_busy = true
	var lobby: DmLobbyClient = slice.party.lobby
	await _teardown_next()
	if lobby != null:
		lobby.close()
	await _enter_next(character, DmLoadingScreen.acquire(self, "Waking the dead..."), _build, {"notice": text} if text != "" else {})
	_party_busy = false


## A guest the host refused or lost while loading: the half-built guest game is dropped and the player lands in their own world again.
func _on_next_join_failed(reason: String, character: Dictionary, loading: DmLoadingScreen) -> void:
	if slice == null:
		return
	var lobby: DmLobbyClient = slice.party.lobby
	var g := slice
	slice = null
	_transit_lobby = null
	g.process_mode = Node.PROCESS_MODE_DISABLED
	g.queue_free()
	if lobby != null:
		lobby.close()
	loading.dismiss()
	await get_tree().process_frame
	await _enter_next(character, DmLoadingScreen.acquire(self, "Waking the dead..."), _build, {"notice": "Could not join: %s" % reason})
	_party_busy = false


## Log out (Settings): final save, the game freed, the token dropped, back to the login screen.
func _on_next_left(logout: bool) -> void:
	await _teardown_next("logout")
	if logout:
		await _send_play_reports_now(2000)   # while the login is still good: the token is dropped next
		api.set_token("")
	_start_flow()


## Switch character (Settings): the same final save and party leave as a log out, but the token stays: the front goes straight to the select screen
## (DmFrontFlow.switch_character; it asks for a password only when the server says the token is no longer good).
func _on_next_switch() -> void:
	if _party_busy or slice == null:
		return
	_party_busy = true
	var lobby: DmLobbyClient = slice.party.lobby
	await _teardown_next("switch")
	if lobby != null:
		lobby.close()
	_party_busy = false
	_start_flow(true)


## A discipline change (the class panel; the server changed the character already): final save, then the game again with the changed character, its bag and progression.
func _on_next_restart(character: Dictionary) -> void:
	await _teardown_next()
	await _enter_world(character, api)


## Ends the running game: the session closes (a host's guests are told) and the scene is freed. `end_reason` ("logout", "switch") also ends the play report; "" is a hand-over (a party, a
## discipline change): the report stops counting this scene and goes on with the next. Either way it is closed before the scene saves, so the final numbers do not wait on the network.
func _teardown_next(end_reason: String = "") -> void:
	var g := slice
	if g == null:
		return
	slice = null
	if report != null:
		report.detach()
	if end_reason != "":
		_end_report(end_reason)
	await g.leave()   # flush_all + session end
	g.queue_free()
	await get_tree().process_frame
