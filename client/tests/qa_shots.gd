extends SceneTree
## The screenshot tool of proposals on the game (client/README.md "Screenshots for proposals"), headless and without a renderer. The tool is the QA driver (main/qa_driver.gd), the shot plan
## (main/qa_ui_shots.gd) and the script that renders a plan (tools/qa_shots.sh); the boot starts the driver (main/main.gd `start_qa`). It checks:
##   - the plan: today's format parses (names, windows and their aliases, hover, clip, wait cap, at most 6 shots and a longer plan refused, equip cap, discipline by name or number, view, turn and anim), what it refuses, every window id a real
##     panel of the HUD, the demo bag's items exist and fit, the discipline table agrees with the content's, with `--class=N` and with tools/qa_shots.sh, and the crop of "clip": "window" in numbers;
##   - the boot's hook: the QA tools start for `--qa` or `--shot-plan=` on the dev-offline backend of a debug build only (a release export and an online start never), as the child Driver of the boot;
##   - the set-up a plan asks for, on the game scene with a dev character on the local mock (never a server): the demo bag and the "give" items in the bag, the "equip" gear worn through the backend's equip call
##     (an unknown id and an item that cannot be worn skipped), the hero's look and the set look at three pieces, the hero healed; per shot the windows (the Reliquary and its tooltip of an item, the Vault in the
##     Chapterhouse), the area the hero stands in, the game view (HUD hidden) and the hero close-up (HUD and windows away, the close-up camera, the turn, the pose frozen) and all of it put back after the picture;
##   - the scripted fight of the driver on the combat core: a pack of the dead arrives (through the core, as ids) and the rites are cast at the nearest one; a "fight" shot (the release checks' hud-fight): the pack made round the hero,
##     cast at and hit, on screen at the end of the wait;
##   - a QA run takes no focus and no mouse (`DmMain.quiet_window`: the main window's `unfocusable` and `mouse_passthrough`): the flags on a window of its own, and in a real launch the boot's line saying it asked for them
##     (a headless run has no window to configure, so only the call path is tested), and none from a launch without the QA flags; its window at the asked `--resolution` even when
##     the screen is smaller (`DmMain.full_size_window`: the size read from `--qa-window=`, since the engine's own `--resolution` never reaches the game; the sizing itself
##     needs a real display, a team PC's screens step);
##   - a real launch (`godot --headless -- --dev-offline --class=2 --qa --shot-plan=... --preset=ultra`): the boot starts the driver, which runs the plan, says the run's preset and that there is no picture to take without a renderer,
##     and leaves the settings file it found as it was;
##   - `--preset=<low|medium|high|ultra>`: honoured only where the QA tools start (`DmMain.qa_preset`: not online, not in a release build, not without --qa or --shot-plan=), an unknown value ignored with a warning; the
##     game scene starts with that preset (the HUD's settings too) and DmSettings holds it on loan: never written to the player's file, written back as the player stored it, an explicit different choice saved as usual;
##   - the clip plan (main/qa_clips.gd; "Clips and tune"): its format, defaults, limits (at most 4 clips of 1-8 s, 0-12 enemies, names), what it refuses, the stand-ins' layouts; the frame writer (main/qa_mjpeg.gd) on made-up pictures
##     (every frame starts FFD8 and ends FFD9, the count matches, 960 px at most and even, a later picture brought to the first's size); a clip recorded on a Reaper's game scene with a made-up picture source (the area, the
##     stand-ins, the HUD away, the camera, the cast LEAD_FRAMES in, the walkers, the files and their json, 30 frames per game second at any frame step, a clip after another starting fresh, a refused rite failing its clip
##     and leaving no file, nothing left behind); `--tune=` (main/qa_tune.gd): the file, every refusal (a file, key or type that is not the data's, a list, null, too many values, a file that cannot be read) changing nothing,
##     a valid tune reaching the rules (DmAbilities), the registry's projections, the combat core's tables and the rite that runs, and being put back; the QA flags honoured only where the QA tools start (a release build,
##     an online start and a launch without a QA flag ignore --clip-plan= and --tune=), and a real launch with both;
##   - the release checks ("Release checks"): `--boot-check` and `--quit-while-loading` honoured by every build (the boot check's line and exit code in real headless launches; the loads need a renderer, so only the
##     call path), `--stutter`, `--soak=` and `--ui-scale=` only where the QA tools start (`DmMain.qa_scenario`, `qa_soak_minutes`, `qa_ui_scale`: a release build, an online start and a launch without a QA flag ignore them), Interface
##     size on loan for a game scene started on it; the stutter scenario's rite list for each discipline and one short run of it on a Reaper (the results file's shape, its rows, the refused rites apart, p50 and p99), the soak
##     scenario's short run (rows, the growth, the file written after each row), the clip plan's `equip` (refusals, the cap) and `turntable` camera (a preview clip with no cast: the hero turns once round in the close-up, the files);
##   - tools/qa_shots.sh with a stand-in for godot (nothing is rendered): Forward+ on the software Vulkan driver with the dev-offline launch line, a scratch user folder and the renderer lock held; the OpenGL 3 fallback
##     with its line when Vulkan cannot start or is not installed or godot chose OpenGL 3 itself, and none when Vulkan ran and a shot failed; the class from the plan's discipline; the time limit and the scratch folder gone after it; bad arguments;
##   - ZERO script errors or engine errors in the log.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/qa_shots.gd

const OUT := "user://qa_shots_test"
## What the plan of the set-up checks asks for: gear for a set look, an id that is no item and one that is no gear, the windows, an area, both views.
const PLAN := '{"give": ["bone_meal"], "equip": ["no_such_item", "staff_moon", "set_gravecaller_head", "set_gravecaller_chest", "set_gravecaller_hands", "tonic_graveluck"], "discipline": "gravecaller", ' \
	+ '"shots": [{"name": "bag-tip", "open": ["bag"], "hover": "item:staff_moon", "clip": "window"}, {"name": "vault", "open": ["vault"], "area": "chapterhouse", "clip": "window"}, ' \
	+ '{"name": "graves", "area": "graves", "view": "game"}, {"name": "hero-back", "view": "hero", "turn": 180, "anim": "cast"}]}'


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL qa_shots: " + what)


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DmSimData.ensure()
	DirAccess.make_dir_recursive_absolute(OUT)
	plan_format()
	clip_plan_format()
	clip_plan_preview()
	mjpeg_writer()
	tune_refusals()
	crop()
	boot_hook()
	scenario_gates()
	await scene_setup()
	await scripted_fight()
	await fight_shot()
	settings_loan()
	await preset_on_game()
	await ui_scale_on_game()
	await tune_and_clips()
	await stutter_and_soak()
	real_launch()
	script_flow()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	_remove_tree(ProjectSettings.globalize_path(OUT))
	print("%s qa_shots %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


# ------------------------------------------------------------------------------------------------------------------ the plan

func plan_format() -> void:
	var p := DmQaUiShots.parse('{"shots":[{"name":"Bag + Tip!","open":["bag"],"hover":3,"wait_ms":99999,"clip":"window"},{"open":"character","area":"chapterhouse"},{"open":["Reliquary","vault"],"hover":"worn:head"}]}')
	check(p["ok"], "a valid plan parses")
	var shots: Array = p["shots"]
	check(shots.size() == 3, "three shots")
	check(shots[0]["name"] == "bag-tip-", "the name is slugged: %s" % shots[0]["name"])
	check(shots[0]["open"] == ["inventory"], "bag -> inventory")
	check(shots[0]["hover"] == 3 and shots[0]["clip"] == "window", "hover slot and clip kept")
	check(shots[0]["wait_ms"] == DmQaUiShots.MAX_WAIT_MS, "wait_ms is capped")
	check(shots[1]["name"] == "shot-2" and shots[1]["open"] == ["sheet"] and shots[1]["area"] == "chapterhouse", "a window as a string, the default name, the area")
	check(shots[2]["open"] == ["inventory", "vault"] and shots[2]["hover"] == "worn:head", "window ids are case-insensitive, the worn hover")
	check(DmQaUiShots.parse('{"shots":[{},{},{},{},{},{}]}')["shots"].size() == DmQaUiShots.MAX_SHOTS and DmQaUiShots.MAX_SHOTS == 6, "6 shots are taken")
	var seven := DmQaUiShots.parse('{"shots":[{},{},{},{},{},{},{}]}')
	check(not seven["ok"] and String(seven["error"]).contains("plan has 7 shots, at most 6 are taken"), "a plan of 7 is refused with the limit said, not trimmed (%s)" % seven["error"])
	check(DmQaUiShots.parse("not json")["ok"] == false, "garbage is refused")
	check(DmQaUiShots.parse('{"shots":[]}')["ok"] == false, "an empty plan is refused")
	check(DmQaUiShots.parse('{"shots":[{"open":["nope"]}]}')["ok"] == false, "an unknown window is refused")
	check(DmQaUiShots.parse('{"shots":[{"hover":48}]}')["ok"] == false, "a slot out of range is refused")
	check(DmQaUiShots.parse('{"shots":[{"hover":"item:staff_moon"}]}')["shots"][0]["hover"] == "item:staff_moon", "an item hover is accepted")
	check(DmQaUiShots.parse('{"give":["staff_oak",""],"shots":[{}]}')["give"] == ["staff_oak"], "the give list is parsed")
	check(DmQaUiShots.parse('{"shots":[{"hover":"head"}]}')["ok"] == false, "a hover that is none of the forms is refused")
	var hp := DmQaUiShots.parse('{"equip":["a","","b"],"discipline":"hero_Rotweaver","shots":[{"view":"hero","turn":180,"anim":"cast"},{"view":"game"},{"view":"hero"},{}]}')
	check(hp["ok"] and hp["equip"] == ["a", "b"] and hp["class_index"] == 4, "the equip list and the discipline are parsed")
	check(hp["shots"][0]["view"] == "hero" and hp["shots"][0]["turn"] == 180.0 and hp["shots"][0]["anim"] == "cast", "the hero view, its turn and its pose are parsed")
	check(hp["shots"][1]["view"] == "game" and hp["shots"][2]["turn"] == DmQaUiShots.DEFAULT_TURN and hp["shots"][3]["view"] == "" and hp["shots"][3]["anim"] == "", "the views' defaults")
	check(DmQaUiShots.parse('{"equip":["1","2","3","4","5","6","7","8","9","10","11","12","13"],"shots":[{}]}')["equip"].size() == DmQaUiShots.MAX_EQUIP, "the equip list is capped")
	check(DmQaUiShots.parse('{"discipline":11,"shots":[{}]}')["class_index"] == 11 and DmQaUiShots.parse('{"shots":[{}]}')["class_index"] == 0, "a discipline by number; none by default")
	check(DmQaUiShots.parse('{"discipline":"grave_warden","shots":[{}]}')["ok"] == false, "a discipline that is not playable is refused")
	check(DmQaUiShots.parse('{"shots":[{"view":"top"}]}')["ok"] == false and DmQaUiShots.parse('{"shots":[{"anim":"dance"}]}')["ok"] == false, "a bad view or pose is refused")
	check(DmQaUiShots.parse('{"shots":[{"fight":true},{"fight":"yes"},{}]}')["shots"].map(func(sh: Dictionary) -> bool: return sh["fight"]) == [true, false, false], "\"fight\" is a true or false, false when it is not given")
	check(DmQaUiShots.parse('{"shots":[{"name":"x"}]}')["bag"] == "demo" and DmQaUiShots.parse('{"bag":"keep","shots":[{}]}')["bag"] == "keep", "the demo bag is the default")
	# the plan's words against the game's: a window id is a panel DmGameUi opens, the disciplines are the content's playable ones, the demo bag is real items that fit
	var known: Array = DmGameUi.PANEL_KEYS.values() + DmGameUi.HOSTS.keys() + ["settings", "salvage", "shelf", "ascension", "class"]
	for k in DmQaUiShots.WINDOWS:
		check(DmQaUiShots.WINDOWS[k] in known, "window %s maps to a real panel id" % k)
	var by_index: Dictionary = DmCombatData.disciplines()["by_index"]
	var script_text := FileAccess.get_file_as_string("res://tools/qa_shots.sh")
	check(script_text != "", "tools/qa_shots.sh is in the project")
	for nm in DmQaUiShots.DISCIPLINES:
		var idx: int = DmQaUiShots.DISCIPLINES[nm]
		check(DmCharacterBuild.is_playable(float(idx)) and String(by_index[str(idx)]) == nm, "%s is a playable discipline at its class index" % nm)
		check(script_text.contains('"%s": %d' % [nm, idx]), "tools/qa_shots.sh maps %s to its class index" % nm)
		check(DmMain.quick_start_class(PackedStringArray(["--dev-offline", "--class=%d" % idx])) == idx, "--class=%d enters the dev quick start as %s" % [idx, nm])
	check(DmQaUiShots.DEMO_BAG.size() <= DmReliquaryPanel.BAG_SIZE, "the demo bag fits")
	for e in DmQaUiShots.DEMO_BAG:
		check(not DmLootData.item(e[0]).is_empty(), "demo item %s exists" % e[0])
	check(DmMain.quick_start_class(PackedStringArray(["--world-demo", "--qa"])) == 2 and DmMain.mode_for(PackedStringArray(["--world-demo"]), true) == "dev_offline", "--world-demo is the dev quick start as class 2")
	check(DmMain.quick_start_class(PackedStringArray(["--dev-offline"])) == -1, "no quick start without --class or --world-demo")


## "clip": "window" in numbers: the window and its tooltip grown by 10, scaled to the picture, cut to it; the whole picture when nothing is left.
func crop() -> void:
	var full := Rect2(0, 0, 1280, 800)
	var ui := Vector2(1600, 900)
	var win := Rect2(400, 100, 800, 600)
	var r := DmQaUiShots.clip_rect(full, ui, win, Rect2())
	var k := full.size / ui
	check(r.is_equal_approx(Rect2(win.grow(10.0).position * k, win.grow(10.0).size * k)), "the crop is the window grown by 10 and scaled to the picture (%s)" % str(r))
	var tip := Rect2(1250, 650, 300, 220)
	var rt := DmQaUiShots.clip_rect(full, ui, win, tip)
	check(rt.encloses(Rect2(tip.position * k, tip.size * k)) and rt.encloses(Rect2(win.position * k, win.size * k)), "a tooltip is inside the crop with its window")
	check(Rect2(Vector2.ZERO, full.size).encloses(rt), "and the crop stays inside the picture")
	check(DmQaUiShots.clip_rect(full, ui, Rect2(-300, -300, 10, 10), Rect2()) == full, "a window outside the picture leaves the whole picture")
	check(DmQaUiShots.clip_rect(full, ui, Rect2(100, 100, 2, 2), Rect2()) != full and DmQaUiShots.clip_rect(full, ui, Rect2(100, 100, 2, 2), Rect2()).size.x > 8, "a small window is grown by its margin")


# ------------------------------------------------------------------------------------------------------------------ the boot's hook

func boot_hook() -> void:
	var qa := PackedStringArray(["--dev-offline", "--class=2", "--qa", "--shot-plan=/x.json", "--shots=/y"])
	check(DmMain.qa_wanted(qa, "dev_offline", true), "the QA tools start for --qa on the dev-offline backend of a debug build")
	check(DmMain.qa_wanted(PackedStringArray(["--dev-offline", "--shot-plan=/x.json"]), "dev_offline", true), "and for --shot-plan= alone")
	check(not DmMain.qa_wanted(PackedStringArray(["--dev-offline", "--class=2"]), "dev_offline", true), "not without either flag")
	check(not DmMain.qa_wanted(qa, "online", true) and not DmMain.qa_wanted(qa, "test", true) and not DmMain.qa_wanted(qa, "benchmark", true), "never on an online start, a test's or the benchmark's")
	check(not DmMain.qa_wanted(qa, "dev_offline", false), "never in a release build")
	check(DmMain.mode_for(qa, false) == "online" and not DmMain.qa_wanted(qa, DmMain.mode_for(qa, false), false), "a release export ignores --dev-offline, so the flags start nothing")
	check(DmMain.qa_wanted(qa, DmMain.mode_for(qa, true), true), "a debug build's mode for these flags is the one that starts them")
	var with_preset := PackedStringArray(["--dev-offline", "--class=2", "--qa", "--preset=low"])
	check(DmMain.qa_preset(with_preset, "dev_offline", true) == "low" and DmMain.qa_preset(PackedStringArray(["--dev-offline", "--shot-plan=/x.json", "--preset=ultra"]), "dev_offline", true) == "ultra",
		"--preset= is honoured in a QA run (--qa or --shot-plan=)")
	for id in DmGraphicsPreset.IDS:
		check(DmMain.qa_preset(PackedStringArray(["--dev-offline", "--qa", "--preset=" + id]), "dev_offline", true) == id, "--preset=%s is a preset" % id)
	check(DmMain.qa_preset(PackedStringArray(["--dev-offline", "--class=2", "--preset=low"]), "dev_offline", true) == "", "ignored without --qa or --shot-plan=")
	check(DmMain.qa_preset(with_preset, "online", true) == "" and DmMain.qa_preset(with_preset, "test", true) == "" and DmMain.qa_preset(with_preset, "benchmark", true) == "", "ignored on an online start, a test's and the benchmark's")
	check(DmMain.qa_preset(with_preset, "dev_offline", false) == "" and DmMain.qa_preset(with_preset, DmMain.mode_for(with_preset, false), false) == "", "ignored in a release build, which does not even start the dev-offline backend")
	check(DmMain.qa_preset(PackedStringArray(["--dev-offline", "--qa"]), "dev_offline", true) == "", "no flag, no preset: the player's own setting is the game's")
	for bad in ["--preset=", "--preset=max", "--preset=LOW", "--preset=low ", "--preset=1", "--preset"]:
		check(DmMain.qa_preset(PackedStringArray(["--dev-offline", "--qa", bad]), "dev_offline", true) == "", "an unknown value (%s) is ignored" % bad)
	var clip := PackedStringArray(["--dev-offline", "--class=11", "--clip-plan=/p.json", "--clips=/c", "--tune=/t.json"])
	check(DmMain.qa_wanted(clip, "dev_offline", true) and DmMain.qa_wanted(PackedStringArray(["--dev-offline", "--clip-plan=/p.json"]), "dev_offline", true), "the QA tools start for --clip-plan= on the dev-offline backend of a debug build")
	check(not DmMain.qa_wanted(clip, "online", true) and not DmMain.qa_wanted(clip, "test", true) and not DmMain.qa_wanted(clip, "benchmark", true) and not DmMain.qa_wanted(clip, "dev_offline", false)
		and not DmMain.qa_wanted(clip, DmMain.mode_for(clip, false), false), "--clip-plan= starts nothing online, in a test or the benchmark, or in a release build")
	check(DmMain.qa_tune(clip, "dev_offline", true) == "/t.json" and DmMain.qa_tune(PackedStringArray(["--dev-offline", "--qa", "--tune=/t.json"]), "dev_offline", true) == "/t.json" and DmMain.qa_tune(PackedStringArray(["--dev-offline", "--shot-plan=/s.json", "--tune=/t.json"]), "dev_offline", true) == "/t.json",
		"--tune= is read in a QA run (--qa, --shot-plan= or --clip-plan=)")
	check(DmMain.qa_tune(clip, "online", true) == "" and DmMain.qa_tune(clip, "test", true) == "" and DmMain.qa_tune(clip, "benchmark", true) == "" and DmMain.qa_tune(clip, "dev_offline", false) == ""
		and DmMain.qa_tune(clip, DmMain.mode_for(clip, false), false) == "", "--tune= is ignored on an online start, a test's, the benchmark's and in a release build")
	check(DmMain.qa_tune(PackedStringArray(["--dev-offline", "--class=2", "--tune=/t.json"]), "dev_offline", true) == "" and DmMain.qa_tune(PackedStringArray(["--dev-offline", "--qa"]), "dev_offline", true) == "",
		"--tune= alone is no QA run (ignored), and a QA run without it has none")
	check(not DmNextGame._wants_warmup(PackedStringArray(["--clip-plan=x.json"]), "X11"), "a clip run takes no warm-up, like the other QA runs")
	var win := Window.new()   # a window of its own: the flags a QA run puts on the main window, read back from the node (a headless display server has none to read)
	check(not win.unfocusable and not win.mouse_passthrough, "a window takes focus and the mouse by default")
	DmMain.quiet_window(win)
	check(win.unfocusable and win.mouse_passthrough, "the QA run's window takes no focus and passes the mouse through")
	DmMain.quiet_window(null)
	win.free()
	check(DmMain.qa_window(PackedStringArray(["--dev-offline", "--qa-window=3840x2160", "--shots=/x"])) == Vector2i(3840, 2160)
		and DmMain.qa_window(PackedStringArray(["--dev-offline"])) == Vector2i.ZERO and DmMain.qa_window(PackedStringArray(["--qa-window="])) == Vector2i.ZERO
		and DmMain.qa_window(PackedStringArray(["--qa-window=big"])) == Vector2i.ZERO and DmMain.qa_window(PackedStringArray(["--qa-window=0x1440"])) == Vector2i.ZERO,
		"--qa-window=WxH is read for the QA window (none, an empty or a bad value: none)")
	check(not OS.get_cmdline_args().has("--fixed-fps") and not OS.get_cmdline_args().has("--headless"),
		"Godot keeps its own options out of the arguments a game reads (why the size comes as --qa-window, not from --resolution): %s" % str(OS.get_cmdline_args()))
	check(DmMain.fast_exit("Windows", false) and not DmMain.fast_exit("Windows", true) and not DmMain.fast_exit("Linux", false) and not DmMain.fast_exit("macOS", false),
		"only a Windows release build ends its own process after its shutdown (B60); a debug build keeps the engine's teardown")
	DmMain.full_size_window(null, Vector2i(3840, 2160))
	DmMain.full_size_window(root, Vector2i.ZERO)   # (a headless display has no window to size: only the call path)
	var m := DmMain.new()
	m.start_qa()
	var d := m.get_node_or_null("Driver")
	check(d != null and d.get_script() != null and String(d.get_script().resource_path) == "res://main/qa_driver.gd", "the boot's child Driver is the QA driver, loaded from its path")
	m.free()


# ------------------------------------------------------------------------------------------------------------------ the set-up a plan asks for

func scene_setup() -> void:
	var mock := DmOffline.make_mock("")   # memory only: no file, no server
	var api := DmOffline.make_api(mock)
	var reg := await api.register("qashots%d" % (Time.get_ticks_usec() % 100000), "q@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"areas": ["chapterhouse", "graves"], "name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "persist": false})
	var hero := g.local_body()
	await until(func() -> bool: return g.local_body().avatar != null, 5.0)
	check(g.ready_ and g.ui != null and g.ui_host != null and hero != null and hero.avatar != null, "the game scene has its HUD, its hero and the avatar")
	check(g.area_id == "chapterhouse", "the hero starts in the Chapterhouse (%s)" % g.area_id)
	var plan := DmQaUiShots.parse(PLAN)
	check(plan["ok"] and plan["class_index"] == 2 and int(g.character["class_index"]) == 2, "the plan parses and its discipline is the game's class")
	hero.p["hp"] = 1.0
	await DmQaUiShots.prepare(g, plan)
	await ticks(6)
	await bag_and_gear(plan)
	var staged: Array[Dictionary] = []
	for s: Dictionary in plan["shots"]:
		var st := await DmQaUiShots.stage(root, g, s)
		staged.append(st)
		await shot_state(s, st)
		var made := DmQaUiShots.capture(root, g, s, st, OUT.path_join("%s.png" % s["name"]))
		check(not made, "%s: a run with no renderer takes no picture and says so (%s)" % [s["name"], DisplayServer.get_name()])
		await ticks(2)
		await view_restored(s, st)
	await hovers_and_windows()
	DmTip.of(root).hide_now()
	DmTip.of(root).test_mouse = null


## The other hovers (a worn piece, an item that is not there) and every window id the plan accepts, opened on the game.
func hovers_and_windows() -> void:
	var plan := DmQaUiShots.parse('{"shots": [{"name": "worn", "open": ["bag"], "hover": "worn:main_hand"}, {"name": "none", "open": ["bag"], "hover": "item:no_such_item"}]}')
	var worn := await DmQaUiShots.stage(root, g, plan["shots"][0])
	var tip := DmTip.of(root)
	check(tip.content != null and _has_text(tip.content, String(DmLootData.item("staff_moon")["name"])) and (worn["tip"] as Rect2).size.x > 50, "a worn: hover shows the card of the piece worn there")
	var none := await DmQaUiShots.stage(root, g, plan["shots"][1])
	check((none["tip"] as Rect2).size == Vector2.ZERO, "a hover on an item that is not in the bag shows nothing and returns no rect")
	DmQaUiShots.go_area(g, "chapterhouse")   # the Vault opens there only
	await ticks(3)
	var opened := {}
	var shut: Array[String] = []
	for k in DmQaUiShots.WINDOWS:
		var id: String = DmQaUiShots.WINDOWS[k]
		if opened.has(id):
			continue
		opened[id] = true
		g.ui.close_panels()
		g.ui.toggle_panel(id)
		await ticks(3)
		if not g.ui.is_open(id) or g.ui.window_for(id) == null or not g.ui.window_for(id).visible:
			shut.append(id)
	g.ui.close_panels()
	check(shut.is_empty() and opened.size() == 21, "every window id the plan accepts opens on the game (%d windows; not: %s)" % [opened.size(), str(shut)])


## A "fight" shot: the pack is made round the hero, the hero casts at it and hits it, the pack is on screen at the end of the wait (what the release checks' hud-fight shot needs).
func fight_shot() -> void:
	var plan := DmQaUiShots.parse('{"shots": [{"name": "hud-fight", "area": "graves", "wait_ms": 3000, "fight": true}]}')
	var casts := [0]
	var cast_cb := func(_slot: int, _aim: Vector3, _enemy: int) -> void: casts[0] += 1
	g.input.hotbar.connect(cast_cb)
	var hits := [0]
	var hit_cb := func(_id: int, _src: int, _amount: float, _hp: float) -> void: hits[0] += 1
	g.core_host.enemy_damaged.connect(hit_cb)
	g.director.enabled = false
	for id in g.core_host.enemies_in_radius(g.local_body().position, 400.0):
		g.core_host.remove_enemy(id)
	var st := await DmQaUiShots.stage(root, g, plan["shots"][0])
	var hero := g.local_body()
	var seen := 0
	var vp := root.get_visible_rect().size
	for id in g.core_host.enemies_in_radius(hero.position, 60.0):
		var p := g.core_host.enemy_position(id)
		if not g.camera.is_position_behind(Vector3(p.x, 0.9, p.z)):
			var sp := g.camera.unproject_position(Vector3(p.x, 0.9, p.z))
			if sp.x >= 0.0 and sp.y >= 0.0 and sp.x <= vp.x and sp.y <= vp.y and g.core_host.enemy_alive(id):
				seen += 1
	check(g.world.area_at(hero.position.x, hero.position.z) == "graves" and g.ui.visible and (st["saved"] as Dictionary).is_empty(), "fight: the hero is in the Graves with the HUD up")
	check(casts[0] >= 5 and hits[0] >= 1, "fight: the hero cast %d times at the pack and hit it %d times" % [casts[0], hits[0]])
	# (the pack is made up again only once it is under FIGHT_FOES - 2, and the casts of the last step can kill after it: 4 is what the picture is promised)
	check(g.core_host.alive_count() >= 4 and seen >= 4, "fight: %d enemies alive, %d of them on screen (at least 4 of each)" % [g.core_host.alive_count(), seen])
	check(float(hero.p["hp"]) >= 0.95 * float(hero.p["stats"]["maxHp"]), "fight: the hero is kept alive and healthy for the picture")
	g.input.hotbar.disconnect(cast_cb)
	g.core_host.enemy_damaged.disconnect(hit_cb)
	for id in g.core_host.enemies_in_radius(hero.position, 400.0):
		g.core_host.remove_enemy(id)


func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while not bool(cond.call()) and Time.get_ticks_msec() < end:
		await process_frame
	return bool(cond.call())


func bag_and_gear(plan: Dictionary) -> void:
	var inv: DmInventory = g.ui_host.inventory
	for e in DmQaUiShots.DEMO_BAG:
		var want: int = int(e[1])
		check(inv.count(e[0]) >= want, "the demo bag holds %s x%d (%d)" % [e[0], want, inv.count(e[0])])
	check(inv.count("ore_iron") == 40 and inv.count("bone_meal") == 13, "stacks as in the plan: 40 iron ore, and the plan's one more bone meal on the demo's 12 (%d)" % inv.count("bone_meal"))
	check(inv.count("no_such_item") == 0 and inv.count("tonic_graveluck") == 3, "an unknown id and a flask to wear changed nothing in the bag (the flask is the demo's 3)")
	var worn := {}
	var worn_by_slot := DmGear.equipped_by_slot(inv.slots)
	for slot in worn_by_slot:
		worn[slot] = String(worn_by_slot[slot]["item_id"])
	check(worn == {"main_hand": "staff_moon", "head": "set_gravecaller_head", "chest": "set_gravecaller_chest", "hands": "set_gravecaller_hands"}, "the gear is worn through the backend's equip call: %s" % str(worn))
	var hero := g.local_body()
	var look: Dictionary = g.look.descriptor()["g"]
	check(look.has("main_hand") and look["main_hand"][0] == "staff_moon" and look["head"][0] == "set_gravecaller_head" and look["chest"][0] == "set_gravecaller_chest" and look["hands"][0] == "set_gravecaller_hands" and look.size() == 4,
		"the hero's look follows the bag: %s" % str(look))
	check(hero.avatar.set_pieces == 3 and hero.avatar.set_id == "gravecaller", "three pieces of one set put the set's look on the avatar (%s x%d)" % [hero.avatar.set_id, hero.avatar.set_pieces])
	check(hero.avatar.slug == "hero_gravecaller", "the discipline's own model (%s)" % hero.avatar.slug)
	check(float(hero.p["hp"]) >= 0.95 * float(hero.p["stats"]["maxHp"]), "the hero is healed for the pictures (%d of %d)" % [int(hero.p["hp"]), int(hero.p["stats"]["maxHp"])])


func shot_state(s: Dictionary, st: Dictionary) -> void:
	var hero := g.local_body()
	match String(s["name"]):
		"bag-tip":
			check(g.ui.is_open("inventory") and g.ui.window_for("inventory").visible, "bag-tip: the Reliquary is open")
			check(g.ui.visible and (st["saved"] as Dictionary).is_empty(), "bag-tip: no view, the HUD stays")
			var tip := DmTip.of(root)
			var name_of: String = String(DmLootData.item("staff_moon")["name"])
			check(tip.content != null and _has_text(tip.content, name_of), "bag-tip: the tooltip is the item's card (%s)" % name_of)
			var r: Rect2 = st["tip"]
			check(r.size.x > 50 and r.size.y > 50 and tip.content.get_global_rect().is_equal_approx(r), "bag-tip: its rect is returned for the crop (%s)" % str(r))
			var win_rect: Rect2 = g.ui.window_for("inventory").get_global_rect()
			var ui_size := root.get_visible_rect().size
			var full := Rect2(Vector2.ZERO, ui_size * 0.8)
			var cr := DmQaUiShots.clip_rect(full, ui_size, win_rect, r)
			check(cr != full and cr.encloses(Rect2(win_rect.position * 0.8, win_rect.size * 0.8).intersection(full)), "bag-tip: the crop is the window and the card, not the whole screen (%s of %s)" % [str(cr.size), str(full.size)])
		"vault":
			check(g.ui.is_open("vault"), "vault: the Vault opens in the Chapterhouse")
			check(g.world.area_at(hero.position.x, hero.position.z) == "chapterhouse", "vault: the plan's area is the Chapterhouse (%s)" % g.world.area_at(hero.position.x, hero.position.z))
			check(not g.ui.is_open("inventory"), "vault: one window at a time")
		"graves":
			check(g.world.area_at(hero.position.x, hero.position.z) == "graves", "graves: the hero stands in the Graves (%s)" % g.world.area_at(hero.position.x, hero.position.z))
			check(not g.ui.panel_open() and not g.ui.visible, "graves: the game view has no window and no HUD")
			check(st["saved"].has("hud") and g.camera.cfg == st["saved"]["cfg"], "graves: the camera is the game's own")
		"hero-back":
			check(not g.ui.visible and not g.ui.panel_open(), "hero-back: the HUD and every window are away")
			check(float(g.camera.cfg["dist"]) == float(DmQaUiShots.HERO_CAM["dist"]) and g.camera.zoom == 1.0 and g.camera.target_zoom == 1.0, "hero-back: the close-up camera")
			check(absf(wrapf(hero.yaw - PI, -PI, PI)) < 0.01, "hero-back: turned 180 degrees to show the back (%s)" % str(hero.yaw))
			check(hero.avatar.c.ap.speed_scale == 0.0, "hero-back: the pose is frozen")
			check(g.world.area_at(hero.position.x, hero.position.z) == "graves", "hero-back: the hero stays where the last shot left him")


## After the picture (taken or not): what the view changed is put back.
func view_restored(s: Dictionary, st: Dictionary) -> void:
	if s["view"] == "":
		return
	var hero := g.local_body()
	check(g.ui.visible, "%s: the HUD is back" % s["name"])
	check(g.camera.cfg == st["saved"]["cfg"] and g.camera.zoom == st["saved"]["zoom"] and g.camera.target_zoom == st["saved"]["target_zoom"], "%s: the camera is put back" % s["name"])
	check(is_equal_approx(hero.yaw, float(st["saved"]["yaw"])) and hero.avatar.c.ap.speed_scale == 1.0, "%s: the hero's turn and pose are put back" % s["name"])


func _has_text(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.contains(needle):
		return true
	if node is RichTextLabel and (node as RichTextLabel).get_parsed_text().contains(needle):
		return true
	for c in node.get_children(true):
		if _has_text(c, needle):
			return true
	return false


# ------------------------------------------------------------------------------------------------------------------ the scripted fight

## The driver's default run on the core (`-- --qa`): a pack of the dead arrives and the rites are cast at the nearest, as ids.
func scripted_fight() -> void:
	DmQaUiShots.go_area(g, "graves")
	await ticks(3)
	var qa: Node = load("res://main/qa_driver.gd").new()
	qa.nxt = g
	qa.t = 11.98
	qa._setup = true
	root.add_child(qa)
	qa.seconds = 1e9
	var casts: Array = []
	g.input.hotbar.connect(func(slot: int, _aim: Vector3, enemy_id: int) -> void: casts.append([slot, enemy_id]))
	for _i in 60:
		qa.t += 0.02
		qa._process_next(0.02)
		await process_frame
	check(g.core_host.alive_count() >= 5, "the fight: a pack of the dead arrives through the core (%d)" % g.core_host.alive_count())
	check(casts.size() > 0 and int(casts[0][1]) != 0, "the fight: rites are cast at an enemy by its id (%d casts)" % casts.size())
	check(qa.casts == casts.size(), "the fight counts its casts (%d)" % qa.casts)
	qa.free()


# ------------------------------------------------------------------------------------------------------------------ the preset flag

## What the hero wears: equipment slot -> item id.
func _worn(game: DmNextGame) -> Dictionary:
	var out := {}
	var by_slot := DmGear.equipped_by_slot(game.ui_host.inventory.slots)
	for slot in by_slot:
		out[slot] = String(by_slot[slot]["item_id"])
	return out


func _sorted_keys(d: Dictionary) -> Array:
	var k := d.keys()
	k.sort()
	return k


func _read_json(path: String) -> Dictionary:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return raw if typeof(raw) == TYPE_DICTIONARY else {}


## DmSettings.session_set: the preset reads as chosen, and what the player stored is what stays in their file.
func settings_loan() -> void:
	var path := ProjectSettings.globalize_path(OUT.path_join("loan_settings.json"))
	var stored := DmSettings.defaults()
	stored["graphics"] = "medium"
	stored["graphics_chosen"] = true
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(stored))
	f.close()
	var s := DmSettings.new(path, true)
	var seen := [0]
	s.changed.connect(func(_v: Dictionary) -> void: seen[0] += 1)
	check(s.values["graphics"] == "medium", "the player's file is read (medium)")
	s.session_set("graphics", "ultra", false)
	check(s.values["graphics"] == "ultra" and seen[0] == 0, "the loan reads as the preset, and says nothing while the game is built")
	s.update({"brightness": 1.1})
	var saved := _read_json(path)
	check(saved.get("graphics") == "medium" and absf(float(saved.get("brightness", 0.0)) - 1.1) < 0.001 and bool(saved.get("graphics_chosen")), "another setting is saved, and the file still holds the player's medium, not the loan")
	check(s.values["graphics"] == "ultra" and seen[0] == 1, "the game keeps reading the preset after that save")
	var echo := s.values.duplicate()   # the Settings panel hands every key back
	echo["vol_master"] = 0.3
	s.update(echo)
	saved = _read_json(path)
	check(saved.get("graphics") == "medium" and absf(float(saved.get("vol_master", 0.0)) - 0.3) < 0.001 and s.values["graphics"] == "ultra", "a whole-dictionary update with the loan's own value saves the others and still not the loan")
	s.session_set("graphics", "low")
	check(s.values["graphics"] == "low" and seen[0] == 3, "a second loan replaces the first and announces itself")
	s.update({"brightness": 1.2})
	check(_read_json(path).get("graphics") == "medium", "and the player's value is still what is saved")
	s.update({"graphics": "high"})
	saved = _read_json(path)
	check(s.values["graphics"] == "high" and saved.get("graphics") == "high" and bool(saved.get("graphics_chosen")), "choosing another preset in Settings is the player's own choice: it is saved")
	s.update({"brightness": 1.0})
	check(s.values["graphics"] == "high" and _read_json(path).get("graphics") == "high", "and the loan is over")
	var again := DmSettings.new(path, true)
	check(again.values["graphics"] == "high", "the next start reads what the player chose")
	var fresh := DmSettings.new(ProjectSettings.globalize_path(OUT.path_join("loan_none.json")), true)
	fresh.session_set("graphics", "low", false)
	check(not FileAccess.file_exists(ProjectSettings.globalize_path(OUT.path_join("loan_none.json"))), "a loan alone writes no file")
	fresh.update({"fps": 30})
	check(_read_json(ProjectSettings.globalize_path(OUT.path_join("loan_none.json"))).get("graphics") == DmGraphicsPreset.DEFAULT, "and a file made after it holds the default, not the preset")


## The game scene with `opts.qa_preset` (what DmMain puts in start_opts): the preset is in force from the start, the HUD's settings read it, and it is on loan, not stored.
func preset_on_game() -> void:
	g.process_mode = Node.PROCESS_MODE_DISABLED
	g.queue_free()
	await process_frame
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("qapreset%d" % (Time.get_ticks_usec() % 100000), "q@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	var p: DmNextGame = load("res://next/next_game.tscn").instantiate()
	p.name = "NextGame"
	root.add_child(p)
	await p.start(ch.data, api, {"areas": ["graves"], "name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "persist": false, "settings": {"graphics": "high"}, "qa_preset": "low"})
	check(p.ready_ and p.perf != null and p.ui_host != null, "the game starts with the flag's preset")
	check(p.perf.preset == "low", "the preset in force is the flag's (low), not the setting the game was given (high): %s" % p.perf.preset)
	check(String(p.ui_host.settings["graphics"]) == "low", "the HUD's settings read the preset too, so the Settings window shows it and nothing puts the old one back")
	var low: Dictionary = DmGraphicsPreset.get_preset("low")
	var vp := p.get_viewport()
	check(p.world.builder.moon.shadow_enabled == bool(low["shadows"]) and not p.world.builder.moon.shadow_enabled and is_equal_approx(p.perf.governor.floor_scale, float(low["floor"]))
		and vp.msaa_3d == DmGraphicsPreset.msaa_mode(int(low["msaa"])), "and the scene is Low's: no moon shadow, Low's resolution floor")
	p.ui_host.settings_store.update({"brightness": 1.0})
	check(p.perf.preset == "low", "a later settings change keeps the preset")
	p.process_mode = Node.PROCESS_MODE_DISABLED
	p.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ clips and tune

func clip_plan_format() -> void:
	var p := DmQaClips.parse('{"discipline": "Reaper", "clips": [{"name": "Wraith Walk!", "area": "graves", "cast": "haunting_wraith", "at": "AHEAD", "enemies": 99, "seconds": 30, "camera": "wide"}, {"cast": "scythe_sweep"}, '
		+ '{"name": "wraith-walk", "cast": "reap", "seconds": 0.2}, {"name": "wraith walk", "cast": "reap", "enemies": 0}, {"name": "fifth", "cast": "reap"}]}')
	check(p["ok"] and p["class_index"] == 11 and p["discipline"] == "reaper", "a clip plan parses, its discipline (by name, any case) is the Reaper's class")
	var clips: Array = p["clips"]
	check(clips.size() == DmQaClips.MAX_CLIPS and DmQaClips.MAX_CLIPS == 4, "at most 4 clips")
	check(clips[0] == {"name": "wraith-walk", "area": "graves", "cast": "haunting_wraith", "at": "ahead", "enemies": 12, "seconds": 8.0, "camera": "wide", "equip": [], "dress": false}, "a clip: the name slugged, enemies and seconds at their limits (%s)" % str(clips[0]))
	check(clips[1] == {"name": "clip-2", "area": "graves", "cast": "scythe_sweep", "at": "pack", "enemies": 6, "seconds": 5.0, "camera": "follow", "equip": [], "dress": false}, "the defaults: the second clip's own name, the Graves, a pack of 6, 5 s, the following camera (%s)" % str(clips[1]))
	check(clips[2]["name"] == "wraith-walk-2" and clips[3]["name"] == "wraith-walk-3" and clips[2]["seconds"] == DmQaClips.MIN_SECONDS and clips[3]["enemies"] == 0, "a name already taken gets a number, a short clip is made 1 s, no enemies is allowed")
	var notes := String(" | ").join(PackedStringArray(p["notes"]))
	check(notes.contains("99 enemies is outside 0-12") and notes.contains("30 seconds is outside 1-8") and notes.contains("0.2 seconds is outside") and notes.contains("the plan has 5 clips, only the first 4 are made"), "what was cut or clamped is said (%s)" % notes)
	check(DmQaClips.parse('{"clips": [{"cast": "reap", "name": "' + "x".repeat(60) + '"}]}')["clips"][0]["name"].length() == DmQaClips.MAX_NAME, "a name is at most %d long" % DmQaClips.MAX_NAME)
	check(DmQaClips.slug("--Hit & Run--", 1) == "hit-run" and DmQaClips.slug("???", 3) == "clip-3" and DmQaClips.parse('{"clips": [{"cast": "reap"}]}')["class_index"] == 0, "a name keeps letters, digits and single hyphens inside; nothing left is clip-<n>; no discipline is none")
	for bad in ['not json', '[]', '{}', '{"clips": []}', '{"clips": [3]}', '{"clips": [{}]}', '{"clips": [{"cast": "no_such_rite"}]}', '{"clips": [{"cast": "reap", "area": "nowhere"}]}', '{"clips": [{"cast": "reap", "at": "behind"}]}',
			'{"clips": [{"cast": "reap", "camera": "top"}]}', '{"clips": [{"cast": "reap", "seconds": "5"}]}', '{"clips": [{"cast": "reap", "enemies": "many"}]}', '{"discipline": "grave_warden", "clips": [{"cast": "reap"}]}']:
		var r := DmQaClips.parse(bad)
		check(not r["ok"] and String(r["error"]) != "", "refused: %s (%s)" % [bad.left(70), r["error"]])
	check(DmQaClips.class_refusal(p, 11) == "" and DmQaClips.class_refusal(DmQaClips.parse('{"clips": [{"cast": "reap"}]}'), 2) == "" and DmQaClips.class_refusal(p, 2).contains("the game runs class 2, the plan wants reaper (11): start it with --class=11"),
		"a game of another class than the plan's discipline is refused with the way to start it; a plan without one takes any")
	# where the stand-ins stand
	var o := Vector3(10.0, 0.0, 5.0)
	var pack := DmQaClips.layout("pack", 12, o)
	var middle := o + DmQaClips.FACING * DmQaClips.PACK_AHEAD
	var apart := 99.0
	for i in pack.size():
		for j in range(i + 1, pack.size()):
			apart = minf(apart, pack[i].distance_to(pack[j]))
	check(pack.size() == 12 and pack[0].is_equal_approx(middle) and pack[1].distance_to(middle) > 1.0 and pack[6].distance_to(middle) < 1.6 and pack[7].distance_to(middle) > 2.9 and apart > 1.2, "a pack of 12 is bunched round the point %d m ahead, nobody on another (%.2f apart)" % [int(DmQaClips.PACK_AHEAD), apart])
	var line := DmQaClips.layout("ahead", 5, o)
	check(line.size() == 5 and absf(line[0].z - (o.z - DmQaClips.LINE_FIRST)) < 1e-4 and absf(line[3].z - (o.z - DmQaClips.LINE_FIRST - 3.0 * DmQaClips.LINE_STEP)) < 1e-4 and line[0].x != line[1].x and absf(line[0].x - o.x) <= 0.5, "a line runs down the facing from %d m, %.1f m apart" % [int(DmQaClips.LINE_FIRST), DmQaClips.LINE_STEP])
	var none: Array[Vector3] = []
	check(DmQaClips.aim_at(pack, o).is_equal_approx(middle) and DmQaClips.aim_at(line, o) == line[0] and DmQaClips.aim_at(none, o).is_equal_approx(middle) and DmQaClips.layout("pack", 0, o).is_empty(), "the rite is aimed at the middle of a pack, the near end of a line, or where a pack would be")


## The frame writer on made-up pictures: the file is a stream of JPEGs and the count, the size and the refusals are as said.
func mjpeg_writer() -> void:
	var path := ProjectSettings.globalize_path(OUT.path_join("fake.mjpeg"))
	var w := DmQaMjpeg.new()
	check(not w.add(Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)) and w.frames == 0, "a writer that is not open takes nothing")
	check(w.open(path), "the writer opens its file")
	for i in 5:
		var img := Image.create_empty(1601, 901, false, Image.FORMAT_RGBA8)   # a window's picture, odd sides, with an alpha channel
		img.fill(Color(float(i) / 5.0, 0.4, 0.8))
		check(w.add(img), "picture %d is taken" % i)
	check(w.add(Image.create_empty(1601, 901, false, Image.FORMAT_RGB8), 3) and w.frames == 8, "a picture given for 3 frames counts 3 (%d)" % w.frames)
	check(not w.add(null) and not w.add(Image.new()) and not w.add(Image.create_empty(8, 8, false, Image.FORMAT_RGB8), 0) and w.frames == 8, "no picture, an empty one and 0 times are refused and count for nothing")
	check(w.add(Image.create_empty(300, 300, false, Image.FORMAT_L8)) and w.frames == 9 and w.width == 960 and w.height == 540, "a later picture of another size and format is brought to the first's size (%dx%d)" % [w.width, w.height])
	w.close()
	var bytes := FileAccess.get_file_as_bytes(path)
	var starts := 0
	var ends := 0
	for i in bytes.size() - 1:
		if bytes[i] == 0xFF and bytes[i + 1] == 0xD8:
			starts += 1
		elif bytes[i] == 0xFF and bytes[i + 1] == 0xD9:
			ends += 1
	check(bytes.size() > 100 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[bytes.size() - 2] == 0xFF and bytes[bytes.size() - 1] == 0xD9, "the file starts FFD8 and ends FFD9")
	check(starts == 9 and ends == 9 and w.frames == 9, "one JPEG for each of the %d frames (%d starts, %d ends)" % [w.frames, starts, ends])
	var cut := 2
	while not (bytes[cut - 2] == 0xFF and bytes[cut - 1] == 0xD9):
		cut += 1
	var first := Image.new()
	check(first.load_jpg_from_buffer(bytes.slice(0, cut)) == OK and first.get_width() == 960 and first.get_height() == 540, "the first frame reads back as a 960x540 JPEG (%dx%d)" % [first.get_width(), first.get_height()])
	var narrow := DmQaMjpeg.new()
	check(narrow.open(path) and narrow.add(Image.create_empty(401, 225, false, Image.FORMAT_RGBA8)) and narrow.width == 400 and narrow.height == 224, "a picture narrower than 960 keeps its width, both sides made even (%dx%d)" % [narrow.width, narrow.height])
	narrow.close()
	check(not DmQaMjpeg.new().open("/no/such/dir/a.mjpeg"), "a file that cannot be written is said")


## The tune's refusals: each changes nothing in the data (and is a line the boot prints).
func tune_refusals() -> void:
	var speed0 := float(DmAbilities.def("haunting_wraith")["speed"])
	var rows := {
		"nope": "the tune must be a JSON object", "[]": "the tune must be a JSON object", '{"combat/abilities": 3}': "must be an object of the keys to change",
		'{"combat/abilties": {"abilities": {}}}': "unknown data file \"combat/abilties\" (the combat files are: combat/abilities",
		'{"abilities": {"x": 1}}': "unknown data file \"abilities\" (a data file is <domain>/<name>",
		'{"sim/world": {"seed": 1}}': "is read fresh by the game",
		'{"combat/abilities": {"abilitis": {"haunting_wraith": {"speed": 5}}}}': "combat/abilities.abilitis is not a key of combat/abilities (it has: abilities,",
		'{"combat/abilities": {"abilities": {"haunting_wraith": {"speeed": 5}}}}': "combat/abilities.abilities.haunting_wraith.speeed is not a key of combat/abilities.abilities.haunting_wraith (it has: id, slot, name",
		'{"combat/abilities": {"abilities": {"no_such_rite": {"speed": 5}}}}': "combat/abilities.abilities.no_such_rite is not a key",
		'{"combat/abilities": {"abilities": {"haunting_wraith": {"speed": "fast"}}}}': "combat/abilities.abilities.haunting_wraith.speed is a number, the tune gives text",
		'{"combat/abilities": {"abilities": {"haunting_wraith": {"speed": true}}}}': "is a number, the tune gives true/false",
		'{"combat/abilities": {"abilities": {"haunting_wraith": {"name": 5}}}}': "is text, the tune gives a number",
		'{"combat/abilities": {"abilities": {"haunting_wraith": {"speed": [1, 2]}}}}': "a tune value is a number, text or true/false, not a list",
		'{"combat/abilities": {"abilities": {"haunting_wraith": {"speed": null}}}}': "a tune value is a number, text or true/false, not empty",
		'{"combat/abilities": {"abilities": {"haunting_wraith": 5}}}': "combat/abilities.abilities.haunting_wraith is an object: name the key inside it that changes",
		'{"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 9, "radius": {"a": 1}}}}}': "combat/abilities.abilities.haunting_wraith.radius is a number, not an object of keys",
		'{"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 9, "nope": 1}}}}': "haunting_wraith.nope is not a key",   # the valid speed before it is not applied either
	}
	for text in rows:
		var parsed := DmQaTune.parse(String(text))
		var r: Dictionary = DmQaTune.apply(parsed["tune"]) if parsed["ok"] else {"ok": false, "error": parsed["error"], "lines": []}
		check(not r["ok"] and String(r["error"]).contains(String(rows[text])), "refused: %s -> %s" % [String(text).left(80), r["error"]])
		check(parsed["ok"] == false or (r["lines"] as Array).size() == 1 and String(r["lines"][0]) == "QA tune refused: " + String(r["error"]), "a refusal is one printed line: %s" % str(r["lines"]).left(60))
	check(float(DmAbilities.def("haunting_wraith")["speed"]) == speed0 and speed0 == 3.5, "none of them changed the data (the wraith's speed is still %s)" % str(speed0))
	var many := {}
	var n := 0
	for id in DmAbilities.defs():
		many[id] = {"cooldownMs": 1000.0, "range": 3.0, "power": 1.0}
		n += 3
		if n > DmQaTune.MAX_VALUES:
			break
	var too := DmQaTune.apply({"combat/abilities": {"abilities": many}})
	check(not too["ok"] and String(too["error"]).contains("more than %d values" % DmQaTune.MAX_VALUES) and float(DmAbilities.def("flail_swing")["cooldownMs"]) == 700.0, "more than %d values in one tune is refused, and none is set" % DmQaTune.MAX_VALUES)
	var dir := ProjectSettings.globalize_path(OUT)
	var big := FileAccess.open(dir.path_join("tune_big.json"), FileAccess.WRITE)
	big.store_string("{\"combat/abilities\": {}}" + " ".repeat(DmQaTune.MAX_BYTES))
	big.close()
	var junk := FileAccess.open(dir.path_join("tune_junk.json"), FileAccess.WRITE)
	junk.store_string("not a tune")
	junk.close()
	var files := {"tune_relative.json": "the tune file must be an absolute path", dir.path_join("tune_missing.json"): "no tune file", dir.path_join("tune_big.json"): "the tune file is too big", dir.path_join("tune_junk.json"): "the tune must be a JSON object"}
	for f in files:
		var r := DmQaTune.apply_file(String(f))
		check(not r["ok"] and String(r["error"]).contains(String(files[f])) and String(r["lines"][0]).begins_with("QA tune refused: "), "a tune file that cannot be used is refused: %s" % r["error"])
	var empty := DmQaTune.apply({})
	var empty2 := DmQaTune.apply({"combat/abilities": {"abilities": {}}})
	check(empty["ok"] and empty["lines"] == ["QA tune: (nothing to change)"] and empty2["ok"] and empty2["lines"] == ["QA tune: (nothing to change)"], "an empty tune is fine (a variant that keeps the data as it is) and says so")
	check(DmQaTune.fmt(5.5) == "5.5" and DmQaTune.fmt(14.0) == "14" and DmQaTune.fmt(14) == "14" and DmQaTune.fmt(0.125) == "0.125" and DmQaTune.fmt("a b") == '"a b"' and DmQaTune.fmt(true) == "true", "a value prints as a number without .0, text quoted, true/false")


## A tune that is valid reaches everything that reads the data, and the clips on a Reaper's game scene. The data is put back at the end.
func tune_and_clips() -> void:
	var tune_path := ProjectSettings.globalize_path(OUT.path_join("tune.json"))
	var tf := FileAccess.open(tune_path, FileAccess.WRITE)
	tf.store_string('{"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 5.5, "range": 9}}}, "content/enemies": {"ENEMIES": {"robber": {"hp": 1234, "xp": 77}}}}')
	tf.close()
	# what is read before the tune is cached (the loot view is a projection of content/enemies), and the core's table before it
	check(float(DmDb.loot_view()["enemies"]["robber"]["xp"]) == 4.0, "the loot view is built from the untuned data (robber xp 4)")
	var base_hp := _core_robber_hp()
	var r := DmQaTune.apply_file(tune_path)
	check(r["ok"] and r["lines"] == ["QA tune: combat/abilities.abilities.haunting_wraith.speed = 5.5", "QA tune: combat/abilities.abilities.haunting_wraith.range = 9", "QA tune: content/enemies.ENEMIES.robber.hp = 1234", "QA tune: content/enemies.ENEMIES.robber.xp = 77"],
		"the tune is applied and each value printed: %s" % str(r.get("lines")))
	check(float(DmAbilities.def("haunting_wraith")["speed"]) == 5.5 and float(DmCombatData.abilities()["abilities"]["haunting_wraith"]["range"]) == 9.0, "the rules read the tuned numbers (DmAbilities, DmCombatData)")
	check(float(DmDb.loot_view()["enemies"]["robber"]["xp"]) == 77.0, "a projection of the data is rebuilt from the tuned data (robber xp 77)")
	var tuned_hp := _core_robber_hp()
	check(base_hp > 0.0 and absf(tuned_hp / base_hp - 1234.0 / 68.0) < 0.01, "the combat core's table is the tuned one (a robber's max health %.1f -> %.1f)" % [base_hp, tuned_hp])
	check(float(DmCoreData.json(ProjectSettings.globalize_path("res://data/content/enemies.json"))["ENEMIES"]["robber"]["hp"]) == 68.0, "a file read by its disk path is the file's (the data files themselves are never written)")
	var put_back := DmQaTune.apply({"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 3.5, "range": 14}}}, "content/enemies": {"ENEMIES": {"robber": {"hp": 68, "xp": 4}}}})
	check(put_back["ok"] and float(DmAbilities.def("haunting_wraith")["speed"]) == 3.5 and float(DmDb.loot_view()["enemies"]["robber"]["xp"]) == 4.0 and absf(_core_robber_hp() - base_hp) < 0.01, "and the data is put back (a tune is its own undo)")
	await clips_on_a_reaper()


## A robber's max health in a fresh core made from the game's data (spawned at level 1, no multiplier).
func _core_robber_hp() -> float:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(11)
	DmCoreData.load_all(c, "res://")
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_wander(false)
	var id: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false, PackedStringArray())
	return float(c.enemy_info(id)["max_hp"]) if id > 0 else 0.0


## Clips recorded on a Reaper's game scene with a made-up picture source (a headless run draws nothing): the area, the stand-ins, the cast and the files.
func clips_on_a_reaper() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("qaclips%d" % (Time.get_ticks_usec() % 100000), "q@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(11)
	var cg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	cg.name = "NextGame"
	root.add_child(cg)
	await cg.start(ch.data, api, {"areas": ["chapterhouse", "graves"], "name": "tester", "hud": true, "audio": false, "seed": 20261019, "waves": true, "persist": false})
	await until(func() -> bool: return cg.local_body().avatar != null, 5.0)
	check(cg.ready_ and int(cg.character["class_index"]) == 11 and cg.area_id == "chapterhouse", "a Reaper's game scene starts in the Chapterhouse")
	var caster := cg.local_body().get_node("Rites") as DmRiteCaster
	var dir := ProjectSettings.globalize_path(OUT.path_join("clips"))
	DirAccess.make_dir_recursive_absolute(dir)
	var plan := DmQaClips.parse('{"discipline": "reaper", "clips": [{"name": "wraith", "cast": "haunting_wraith", "at": "ahead", "enemies": 4, "seconds": 2, "camera": "wide"}, {"name": "second", "cast": "haunting_wraith", "at": "pack", "enemies": 3, "seconds": 1}]}')
	check(plan["ok"] and DmQaClips.class_refusal(plan, int(cg.character["class_index"])) == "", "the plan parses and the game is the class it wants")
	var hurt := [0]
	cg.core_host.enemy_damaged.connect(func(_id: int, _src: int, _amount: float, _hp: float) -> void: hurt[0] += 1)
	var seen := {"n": 0}
	var fake := func() -> Image:
		seen["n"] += 1
		if seen["n"] == 12:   # 0.4 s in: the rite was cast at frame 6
			var walkers: Array = caster.mem("haunting_wraith").get("walkers", [])
			seen["walkers"] = walkers.size()
			seen["speed"] = float(walkers[0]["speed"]) if not walkers.is_empty() else -1.0
			seen["alive"] = cg.core_host.alive_count()
			seen["hud"] = cg.ui.visible
			seen["zoom"] = cg.camera.zoom
			seen["area"] = cg.area_id
			seen["waves"] = cg.director.enabled
			seen["souls"] = int(caster.p["souls"])
			seen["bag"] = int(caster.p["soulsMax"])
		var img := Image.create_empty(401, 225, false, Image.FORMAT_RGBA8)
		img.fill(Color.from_hsv(fmod(float(seen["n"]) * 0.02, 1.0), 0.7, 0.8))
		return img
	var a: Dictionary = await DmQaClips.record(root, cg, plan["clips"][0], dir, fake)
	check(a["ok"] and a["frames"] == 60 and a["width"] == 400 and a["height"] == 224 and a["casts"] == [DmQaClips.LEAD_FRAMES], "the first clip: 2 s is 60 frames of 400x224, the rite cast at frame %d (%s)" % [DmQaClips.LEAD_FRAMES, str(a)])
	check(seen["n"] >= 20 and seen["n"] <= 60, "30 frames per game second whatever the engine's frame step (this run steps %.4f s: %d pictures read back for 60 frames)" % [float(a.get("step", 0.0)), seen["n"]])
	check(seen.get("area") == "graves" and seen.get("alive") == 4 and not seen.get("hud", true) and absf(float(seen.get("zoom", 0.0)) - float(cg.camera.cfg["zoomMax"])) < 0.01 and not seen.get("waves", true),
		"while recording: in the area, four stand-ins and no others, the HUD away, the widest camera, no waves (%s)" % str(seen))
	check(seen.get("walkers") == 1 and seen.get("speed") == 3.5 and seen.get("souls", 0) == int(seen.get("bag", 0)) - 5, "the wraith walks at the data's speed (%s m/s)" % str(seen.get("speed")))
	await ticks(4)
	check(hurt[0] > 0 and cg.core_host.alive_count() == 0 and caster.mem("haunting_wraith").get("walkers", []).is_empty(), "the wraith hurt the stand-ins (%d blows), which are sent away after the clip with nothing of the rite left walking" % hurt[0])
	var bytes := FileAccess.get_file_as_bytes(dir.path_join("wraith.mjpeg"))
	var starts := 0
	var ends := 0
	for i in bytes.size() - 1:
		if bytes[i] == 0xFF and bytes[i + 1] == 0xD8:
			starts += 1
		elif bytes[i] == 0xFF and bytes[i + 1] == 0xD9:
			ends += 1
	check(starts == 60 and ends == 60 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[bytes.size() - 1] == 0xD9, "wraith.mjpeg is 60 JPEGs, FFD8 to FFD9 each")
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("wraith.json")))
	check(meta is Dictionary and (meta as Dictionary).size() == 5 and meta["fps"] == 30.0 and meta["frames"] == 60.0 and meta["width"] == 400.0 and meta["height"] == 224.0 and meta["cast_at_frame"] == 6.0, "wraith.json is {fps, frames, width, height, cast_at_frame}: %s" % str(meta))
	# the next clip starts as the first did, though the first's rite is on its 14 s cooldown: the caster was made fresh
	seen["n"] = 0
	var b: Dictionary = await DmQaClips.record(root, cg, plan["clips"][1], dir, fake)
	check(b["ok"] and b["frames"] == 30 and b["casts"] == [DmQaClips.LEAD_FRAMES] and FileAccess.file_exists(dir.path_join("second.mjpeg")) and FileAccess.file_exists(dir.path_join("second.json")), "a second clip: 30 frames, cast at frame %d again (%s)" % [DmQaClips.LEAD_FRAMES, str(b)])
	check(seen.get("alive") == 3 and seen.get("zoom") != null and absf(float(seen["zoom"]) - 1.0) < 0.01, "with its own stand-ins and the game's own camera (%s)" % str(seen))
	# a model preview: items worn, the turntable camera, no cast
	var tplan := DmQaClips.parse('{"discipline": "reaper", "equip": ["staff_moon", "helm_gold"], "clips": [{"name": "preview", "camera": "turntable", "seconds": 2}, {"name": "only-staff", "camera": "turntable", "seconds": 1, "equip": ["staff_moon"]}, {"name": "bare", "camera": "turntable", "seconds": 1, "equip": []}]}')
	var yaws: Array[float] = []
	var view := {}
	var turn := func() -> Image:
		yaws.append(cg.local_body().yaw)
		if yaws.size() == 20:
			view["dist"] = float(cg.camera.cfg["dist"])
			view["hud"] = cg.ui.visible
			view["alive"] = cg.core_host.alive_count()
			view["area"] = cg.area_id
			view["worn"] = _worn(cg)
		var img := Image.create_empty(401, 225, false, Image.FORMAT_RGBA8)
		img.fill(Color.from_hsv(fmod(float(yaws.size()) * 0.03, 1.0), 0.6, 0.7))
		return img
	var tv: Dictionary = await DmQaClips.record(root, cg, tplan["clips"][0], dir, turn)
	check(tv["ok"] and tv["frames"] == 60 and tv["casts"] == [] and yaws.size() >= 20, "a preview clip with no cast is recorded: 60 frames (%s)" % str(tv))
	check(yaws[0] < 0.2 and yaws[yaws.size() - 1] > TAU * 0.9 and yaws[yaws.size() - 1] < TAU and yaws.size() > 2 and yaws[yaws.size() / 2] > 2.5 and yaws[yaws.size() / 2] < 3.8, "the hero turns once round over the clip (%.2f to %.2f rad)" % [yaws[0], yaws[yaws.size() - 1]])
	check(absf(float(view.get("dist", 0.0)) - float(DmQaUiShots.HERO_CAM["dist"])) < 0.01 and view.get("hud") == false and view.get("alive") == 0 and view.get("area") == "chapterhouse", "in the hero's close-up in the Chapterhouse with the HUD away and no enemies (%s)" % str(view))
	check(view.get("worn", {}).get("main_hand") == "staff_moon" and view.get("worn", {}).get("head") == "helm_gold", "the plan's equip is worn by the hero through the backend's equip call (%s)" % str(view.get("worn")))
	view.clear()
	yaws.clear()
	var tv2: Dictionary = await DmQaClips.record(root, cg, tplan["clips"][1], dir, turn)
	check(tv2["ok"] and view.get("worn", {}).get("main_hand") == "staff_moon" and not view.get("worn", {}).has("head"), "a clip's own list wins: the helm is taken off, the staff stays (%s)" % str(view.get("worn")))
	view.clear()
	yaws.clear()
	var tv3: Dictionary = await DmQaClips.record(root, cg, tplan["clips"][2], dir, turn)
	check(tv3["ok"] and (view.get("worn", {}) as Dictionary).is_empty() and tv3["frames"] == 30, "and an empty list takes everything off (%s)" % str(view.get("worn")))
	var tmeta: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("preview.json")))
	check(tmeta is Dictionary and tmeta["cast_at_frame"] == -1.0 and tmeta["frames"] == 60.0 and FileAccess.file_exists(dir.path_join("preview.mjpeg")), "preview.json says the cast frame is -1 (no cast): %s" % str(tmeta))
	# a tune reaches the rite that is cast
	var tuned := DmQaTune.apply({"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 6.0}}}})
	seen["n"] = 0
	var c: Dictionary = await DmQaClips.record(root, cg, plan["clips"][1], dir, fake)
	check(tuned["ok"] and c["ok"] and seen.get("speed") == 6.0, "the wraith of a tuned run walks at the tuned speed (%s m/s)" % str(seen.get("speed")))
	# a rite the host refuses fails its clip and leaves no file
	var dear := DmQaTune.apply({"combat/abilities": {"abilities": {"haunting_wraith": {"soulCost": 99}}}})
	var d: Dictionary = await DmQaClips.record(root, cg, plan["clips"][0], dir, fake)
	check(dear["ok"] and not d["ok"] and String(d["why"]).contains("the rite was refused (souls)") and not FileAccess.file_exists(dir.path_join("wraith.mjpeg")) and not FileAccess.file_exists(dir.path_join("wraith.json")), "a rite the hero cannot pay for fails its clip, saying why, and leaves no file (%s)" % d["why"])
	# a picture source that gives nothing fails the clip, and removes what it began
	var blank := func() -> Image: return null
	DmQaTune.apply({"combat/abilities": {"abilities": {"haunting_wraith": {"soulCost": 5, "speed": 3.5}}}})
	var e: Dictionary = await DmQaClips.record(root, cg, plan["clips"][1], dir, blank)
	check(not e["ok"] and String(e["why"]).contains("no picture") and not FileAccess.file_exists(dir.path_join("second.mjpeg")), "a run that draws nothing fails its clip and leaves no file (%s)" % e["why"])
	check(float(DmAbilities.def("haunting_wraith")["speed"]) == 3.5 and int(DmAbilities.def("haunting_wraith")["soulCost"]) == 5 and float(DmAbilities.def("haunting_wraith")["range"]) == 14.0, "the data is as it was")
	cg.process_mode = Node.PROCESS_MODE_DISABLED
	cg.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ release checks

## The clip plan's model previews: `equip` (items worn by the hero) and the `turntable` camera.
func clip_plan_preview() -> void:
	var p := DmQaClips.parse('{"discipline": "reaper", "equip": ["staff_moon", "helm_gold"], "clips": [{"name": "preview", "camera": "turntable"}, {"name": "spin", "camera": "Turntable", "cast": "reap", "enemies": 3, "seconds": 3}]}')
	check(p["ok"] and p["equip"] == ["staff_moon", "helm_gold"], "a clip plan's equip list is parsed (%s)" % str(p.get("error")))
	check(p["clips"][0] == {"name": "preview", "area": "chapterhouse", "cast": "", "at": "pack", "enemies": 0, "seconds": 6.0, "camera": "turntable", "equip": ["staff_moon", "helm_gold"], "dress": true},
		"a turntable clip needs no cast, area or length: the Chapterhouse, no enemies, 6 s, wearing the plan's items (%s)" % str(p["clips"][0]))
	var own := DmQaClips.parse('{"clips": [{"name": "a", "camera": "turntable", "equip": ["staff_moon"]}, {"name": "b", "cast": "reap"}, {"name": "c", "camera": "turntable", "equip": [], "area": "graves"}]}')
	check(own["ok"] and own["equip"] == [] and own["clips"][0]["equip"] == ["staff_moon"] and own["clips"][1]["equip"] == [] and own["clips"][2]["equip"] == [] and own["clips"][2]["area"] == "graves" and own["clips"][0]["dress"] and own["clips"][1]["dress"],
		"a clip's own equip list is its own, and a plan that names items anywhere sets what is worn for every clip (%s)" % str(own.get("error")))
	var over := DmQaClips.parse('{"equip": ["staff_moon", "helm_gold"], "clips": [{"camera": "turntable", "equip": ["helm_gold"]}, {"camera": "turntable"}]}')
	check(over["ok"] and over["clips"][0]["equip"] == ["helm_gold"] and over["clips"][1]["equip"] == ["staff_moon", "helm_gold"], "a clip's list wins over the plan's, and a clip without one wears the plan's")
	check(not DmQaClips.parse('{"clips": [{"camera": "turntable", "equip": ["bone_meal"]}]}')["ok"] and not DmQaClips.parse('{"clips": [{"camera": "turntable", "equip": "staff_moon"}]}')["ok"], "a clip's own list is refused like the plan's")
	check(p["clips"][1]["cast"] == "reap" and p["clips"][1]["enemies"] == 3 and p["clips"][1]["seconds"] == 3.0 and p["clips"][1]["camera"] == "turntable", "and may still cast, with enemies, for any length")
	check(DmQaClips.parse('{"clips": [{"cast": "reap"}]}')["equip"] == [], "no equip list is none")
	for bad in ['{"equip": "staff_moon", "clips": [{"cast": "reap"}]}', '{"equip": ["no_such_item"], "clips": [{"cast": "reap"}]}', '{"equip": ["bone_meal"], "clips": [{"cast": "reap"}]}', '{"clips": [{"camera": "follow"}]}',
			'{"clips": [{"cast": "reap", "camera": "orbit"}]}']:
		var r := DmQaClips.parse(bad)
		check(not r["ok"] and String(r["error"]) != "", "refused: %s (%s)" % [bad.left(70), r["error"]])
	var many := DmQaClips.parse('{"equip": [' + ", ".join(PackedStringArray(Array(range(DmQaUiShots.MAX_EQUIP + 3)).map(func(_i: int) -> String: return '"staff_moon"'))) + '], "clips": [{"cast": "reap"}]}')
	check(many["ok"] and many["equip"].size() == DmQaUiShots.MAX_EQUIP and String(many["notes"][0]).contains("only the first %d" % DmQaUiShots.MAX_EQUIP), "no more than %d items are worn, and the plan says so" % DmQaUiShots.MAX_EQUIP)


## What reads the release checks' flags: `--boot-check` and `--quit-while-loading` in every build; `--stutter`, `--soak=` and `--ui-scale=` only where the QA tools start.
func scenario_gates() -> void:
	var boot := PackedStringArray(["--boot-check", "--quit-while-loading"])
	check(DmMain.boot_check(boot) and not DmMain.boot_check(PackedStringArray(["--boot-smoke"])) and not DmMain.boot_check(PackedStringArray()), "--boot-check is read from the launch line, in a release build too (it takes no build argument)")
	check(not DmMain.qa_wanted(boot, "dev_offline", true) and not DmMain.qa_wanted(boot, "online", false), "and is no QA flag: it starts none of the QA tools")
	var stutter := PackedStringArray(["--dev-offline", "--stutter", "--stutter-out=/out"])
	var soak := PackedStringArray(["--dev-offline", "--soak=5", "--soak-out=/out"])
	check(DmMain.qa_wanted(stutter, "dev_offline", true) and DmMain.qa_wanted(soak, "dev_offline", true) and DmMain.qa_wanted(PackedStringArray(["--dev-offline", "--soak"]), "dev_offline", true), "--stutter and --soak start the QA tools on the dev-offline backend of a debug build")
	check(DmMain.qa_scenario(stutter, "dev_offline", true) == "stutter" and DmMain.qa_scenario(soak, "dev_offline", true) == "soak" and DmMain.qa_scenario(PackedStringArray(["--dev-offline", "--soak"]), "dev_offline", true) == "soak"
		and DmMain.qa_scenario(PackedStringArray(["--dev-offline", "--soak", "--stutter"]), "dev_offline", true) == "stutter" and DmMain.qa_scenario(PackedStringArray(["--dev-offline", "--qa"]), "dev_offline", true) == "",
		"the scenario is read from the flag (a launch with neither has none)")
	for m in ["online", "test", "benchmark"]:
		check(DmMain.qa_scenario(stutter, m, true) == "" and DmMain.qa_scenario(soak, m, true) == "" and not DmMain.qa_wanted(stutter, m, true), "no scenario on a %s start" % m)
	check(DmMain.qa_scenario(stutter, "dev_offline", false) == "" and DmMain.qa_scenario(soak, DmMain.mode_for(soak, false), false) == "" and not DmMain.qa_wanted(stutter, DmMain.mode_for(stutter, false), false), "none in a release build, which does not even start the dev-offline backend")
	check(DmMain.qa_scenario(PackedStringArray(["--dev-offline", "--class=2", "--stutter-out=/out"]), "dev_offline", true) == "" and DmMain.qa_results(stutter, "stutter") == "/out/stutter.json" and DmMain.qa_results(soak, "soak") == "/out/soak.json"
		and DmMain.qa_results(stutter, "soak") == "" and DmMain.qa_results(PackedStringArray(["--stutter"]), "stutter") == "" and DmMain.qa_results(PackedStringArray(["--stutter-out="]), "stutter") == "", "--stutter-out= and --soak-out= name the folder, alone they are no scenario")
	check(DmMain.qa_soak_minutes(PackedStringArray(["--soak"])) == 30.0 and DmMain.qa_soak_minutes(soak) == 5.0 and DmMain.qa_soak_minutes(PackedStringArray(["--soak=0.5"])) == 0.5 and DmMain.qa_soak_minutes(PackedStringArray(["--soak=0"])) == 30.0
		and DmMain.qa_soak_minutes(PackedStringArray(["--soak=abc"])) == 30.0 and DmMain.qa_soak_minutes(PackedStringArray(["--soak=-3"])) == 30.0, "--soak runs 30 minutes unless it says a number above 0")
	var scale := PackedStringArray(["--dev-offline", "--class=2", "--qa", "--ui-scale=1.25"])
	check(DmMain.qa_ui_scale(scale, "dev_offline", true) == 1.25 and DmMain.qa_ui_scale(PackedStringArray(["--dev-offline", "--shot-plan=/s.json", "--ui-scale=0.8"]), "dev_offline", true) == 0.8 and DmMain.qa_ui_scale(PackedStringArray(["--dev-offline", "--qa", "--ui-scale=1"]), "dev_offline", true) == 1.0,
		"--ui-scale= is read in a QA run, as Settings' Interface size offers it (0.8 to 1.25)")
	check(DmMain.qa_ui_scale(scale, "online", true) == 0.0 and DmMain.qa_ui_scale(scale, "test", true) == 0.0 and DmMain.qa_ui_scale(scale, "benchmark", true) == 0.0 and DmMain.qa_ui_scale(scale, "dev_offline", false) == 0.0 and DmMain.qa_ui_scale(scale, DmMain.mode_for(scale, false), false) == 0.0,
		"--ui-scale= is ignored on an online start, a test's, the benchmark's and in a release build")
	check(DmMain.qa_ui_scale(PackedStringArray(["--dev-offline", "--class=2", "--ui-scale=1.25"]), "dev_offline", true) == 0.0 and DmMain.qa_ui_scale(PackedStringArray(["--dev-offline", "--qa"]), "dev_offline", true) == 0.0, "and without a QA flag, or without the flag")
	for bad in ["--ui-scale=2", "--ui-scale=0.5", "--ui-scale=big", "--ui-scale="]:
		check(DmMain.qa_ui_scale(PackedStringArray(["--dev-offline", "--qa", bad]), "dev_offline", true) == 0.0, "a value Settings does not offer (%s) is ignored" % bad)
	# the stutter scenario's rites: each discipline's primaries, hotbar, grimoire and signature, once, all with a module
	for disc in DmQaUiShots.DISCIPLINES.values():
		var rites := DmQaStutter.rites_of(int(disc))
		var did := String(DmCombatData.disciplines()["by_index"][str(disc)])
		var kit := DmAbilities.kit_for(DmHeroBody.family_of(did))
		var unique := {}
		for r in rites:
			unique[r] = true
		check(rites.size() > 5 and unique.size() == rites.size() and rites.all(func(r: String) -> bool: return DmRiteRegistry.has(r)), "%s: %d rites, once each, every one with a module" % [DmQaStutter.name_of(int(disc)), rites.size()])
		check(rites.has(String(kit["defaultPrimary"])) and rites.has(String(kit["rmb"])) and rites.has(String(kit["signatures"][did])) and (kit["defaultLoadout"] as Array).all(func(r: String) -> bool: return rites.has(r)), "%s: the primary, the four of the hotbar, the right mouse button's and the signature are among them" % did)
	check(DmQaStutter.rites_of(11).has("haunting_wraith") and DmQaStutter.rites_of(2).has("command_rend") and DmQaStutter.name_of(11) == "reaper" and DmQaStutter.name_of(1) == "ossuary", "the Reaper's grimoire and the Gravecaller's signature are in, and the names are the discipline names")
	check(DmQaPerf.percentile(PackedFloat32Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 100]), 10, 50.0) == 5.0 and DmQaPerf.percentile(PackedFloat32Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 100]), 10, 99.0) == 100.0 and DmQaPerf.percentile(PackedFloat32Array(), 0, 50.0) == 0.0
		and DmQaPerf.frame_stats(PackedFloat32Array([5, 1, 3, 7, 100]), 4) == {"frames": 4, "p50_ms": 3.0, "p99_ms": 7.0, "worst_ms": 7.0}, "the frame statistics: nearest rank, over the frames counted only")
	var growth := DmQaSoak.growth([{"p50_ms": 4.0, "p99_ms": 8.0, "static_mb": 100.0, "objects": 1000, "video_mb": 50.0}, {"p50_ms": 5.0, "p99_ms": 9.0, "static_mb": 110.0, "objects": 1100, "video_mb": 55.0},
		{"p50_ms": 6.0, "p99_ms": 12.0, "static_mb": 130.0, "objects": 1300, "video_mb": 60.0}])
	var rows3: Array = [{"p50_ms": 4.0, "p99_ms": 8.0, "static_mb": 100.0, "objects": 1000, "video_mb": 50.0}, {"p50_ms": 5.0, "p99_ms": 9.0, "static_mb": 110.0, "objects": 1100, "video_mb": 55.0}, {"p50_ms": 6.0, "p99_ms": 12.0, "static_mb": 130.0, "objects": 1300, "video_mb": 60.0}]
	var detail := DmQaSoak.growth_detail(rows3)
	check(growth == {"static_mb": 30.0, "objects": 300.0, "video_mb": 10.0, "p99_ms": 4.0} and detail["window_min"] == 1 and detail["static_mb"] == {"first": 100.0, "last": 130.0, "delta": 30.0} and DmQaSoak.growth([]).is_empty(),
		"the soak's growth is the mean of the last rows minus the first (%s)" % str(growth))
	var rows12: Array = []
	for i in 12:   # 12 rows: the last 5 against the first 5 (the memory climbs 10 MB a row)
		rows12.append({"p50_ms": 5.0, "p99_ms": 8.0 + i, "static_mb": 100.0 + 10.0 * i, "objects": 1000 + 100 * i, "video_mb": 50.0})
	var g12 := DmQaSoak.growth(rows12)
	check(DmQaSoak.growth_detail(rows12)["window_min"] == 5 and g12["static_mb"] == 70.0 and g12["objects"] == 700.0 and g12["video_mb"] == 0.0 and g12["p99_ms"] == 7.0, "over 5 minutes at 10 or more rows (%s)" % str(g12))
	check(DmQaSoak.growth([rows3[0]]) == {"static_mb": 0.0, "objects": 0.0, "video_mb": 0.0, "p99_ms": 0.0}, "and one row is no growth")


## A game scene started on `--ui-scale=`: Settings' Interface size is the flag's for the run, never the stored one.
func ui_scale_on_game() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("qascale%d" % (Time.get_ticks_usec() % 100000), "q@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	var p: DmNextGame = load("res://next/next_game.tscn").instantiate()
	p.name = "NextGame"
	root.add_child(p)
	await p.start(ch.data, api, {"areas": ["graves"], "name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "persist": false, "settings": {"graphics": "high", "ui_scale": 0.9}, "qa_ui_scale": 1.25})
	check(p.ready_ and p.ui_host != null and absf(float(p.ui_host.settings["ui_scale"]) - 1.25) < 0.001, "the HUD's settings read the flag's Interface size (%s), not the setting the game was given (0.9)" % str(p.ui_host.settings["ui_scale"]))
	p.ui_host.settings_store.update({"brightness": 1.0})
	check(absf(float(p.ui_host.settings["ui_scale"]) - 1.25) < 0.001, "a later settings change keeps it")
	p.process_mode = Node.PROCESS_MODE_DISABLED
	p.queue_free()
	await process_frame


## One short run of each scenario on isolated offline games: the results files' shape and rows. (The real ones take minutes: a team PC's; the launch itself, on the VPS, by hand.)
func stutter_and_soak() -> void:
	var dir := ProjectSettings.globalize_path(OUT)
	var st := DmQaStutter.new()
	st.name = "Scenario"
	st.disciplines = [11]
	st.max_rites = 3
	st.window_s = 0.4
	st.gap_s = 0.1
	st.settle_s = 0.5
	st.results_file = dir.path_join("stutter_out/stutter.json")   # a folder the run makes
	root.add_child(st)
	var code: int = await st.run()
	check(code == 0 and st.errors.is_empty(), "a short stutter run ends with exit code 0 (%d, %s)" % [code, str(st.errors)])
	var rep: Variant = JSON.parse_string(FileAccess.get_file_as_string(st.results_file))
	var ok := rep is Dictionary
	check(ok and rep["scenario"] == "stutter" and rep["preset"] == "high" and rep["compilations_counted"] == true and rep["rows"] is Array and rep["refused"] is Array and rep["errors"] == [], "the results file: scenario, preset, the rows, the refused, no errors")
	if ok:
		var rows: Array = rep["rows"]
		var asked: Array = DmQaStutter.rites_of(11).slice(0, 3)
		var seen: Array = rows.map(func(r: Dictionary) -> String: return String(r["rite"])) + (rep["refused"] as Array).map(func(r: Dictionary) -> String: return String(r["rite"]))
		seen.sort()
		asked.sort()
		check(seen == asked, "the first three rites of the Reaper were each measured or refused (%s of %s)" % [str(seen), str(asked)])
		var shaped := not rows.is_empty()
		for r: Dictionary in rows:
			shaped = shaped and _sorted_keys(r) == ["compilations", "discipline", "rite", "worst_ms"] and r["discipline"] == "reaper" and r["worst_ms"] is float and float(r["worst_ms"]) > 0.0 and r["compilations"] is float and float(r["compilations"]) == 0.0
		check(shaped, "a row is {discipline, rite, worst_ms, compilations}: the worst frame of its second and the pipelines compiled (none: there is no renderer here) (%s)" % str(rows.slice(0, 2)))
		check(rep["p50_ms"] is float and rep["p99_ms"] is float and float(rep["p50_ms"]) > 0.0 and float(rep["p99_ms"]) >= float(rep["p50_ms"]) and float(rep["worst_ms"]) >= float(rep["p99_ms"]) and int(rep["frames"]) > 0 and float(rep["ms"]) > 0.0,
			"the run's p50 %s and p99 %s ms over %s frames" % [str(rep["p50_ms"]), str(rep["p99_ms"]), str(rep["frames"])])
		for r: Dictionary in rep["refused"]:
			check(_sorted_keys(r) == ["discipline", "reason", "rite"] and String(r["reason"]) != "", "a refused rite says why (%s)" % str(r))
	st.free()
	await process_frame
	var sk := DmQaSoak.new()
	sk.name = "Scenario"
	sk.minutes = 0.1
	sk.row_s = 2.0
	sk.results_file = dir.path_join("soak_out/soak.json")
	root.add_child(sk)
	var scode: int = await sk.run()
	var soak: Variant = JSON.parse_string(FileAccess.get_file_as_string(sk.results_file))
	check(scode == 0 and soak is Dictionary and soak["scenario"] == "soak" and soak["complete"] == true and soak["rows"].size() == 3 and soak["discipline"] == "gravecaller" and float(soak["minutes"]) == 0.1, "a short soak run: 3 rows, complete, exit code 0 (%d)" % scode)
	if soak is Dictionary:
		var good := true
		for i in (soak["rows"] as Array).size():
			var row: Dictionary = soak["rows"][i]
			good = good and int(row["minute"]) == i + 1 and int(row["frames"]) > 0 and float(row["p50_ms"]) > 0.0 and float(row["p99_ms"]) >= float(row["p50_ms"]) and float(row["static_mb"]) > 0.0 and int(row["objects"]) > 0 and row.has("video_mb") and row.has("nodes") and row.has("worst_ms") and row.has("kills")
		check(good, "each row: the minute, the frames, p50 and p99, static memory, objects, video memory (%s)" % str((soak["rows"] as Array)[0]))
		var g: Dictionary = soak["growth"]
		var gd: Dictionary = soak["growth_detail"]
		check(_sorted_keys(g) == ["objects", "p99_ms", "static_mb", "video_mb"] and gd["window_min"] == 1.0 and _sorted_keys(gd["static_mb"]) == ["delta", "first", "last"] and absf(float(g["static_mb"]) - (float(soak["rows"][2]["static_mb"]) - float(soak["rows"][0]["static_mb"]))) < 0.02,
			"and the growth of the last row against the first: {static_mb, objects, video_mb, p99_ms} (%s)" % str(g))
	sk.free()
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ a real launch

## `godot --headless -- --dev-offline --class=2 --no-waves --qa --shot-plan=... --shots=...` as the script starts it, without a renderer: the boot starts the driver, which runs the plan.
func real_launch() -> void:
	var plan_file := ProjectSettings.globalize_path(OUT.path_join("launch_plan.json"))
	var shots := ProjectSettings.globalize_path(OUT.path_join("launch_shots"))
	var f := FileAccess.open(plan_file, FileAccess.WRITE)
	f.store_string('{"equip": ["staff_moon"], "shots": [{"name": "bag", "open": ["bag"], "hover": "item:staff_moon", "clip": "window"}, {"name": "hero", "view": "hero", "turn": 0}, {"name": "away", "area": "graves", "open": ["vault"]}]}')
	f.close()
	var data := ProjectSettings.globalize_path(OUT.path_join("launch_xdg"))
	DirAccess.make_dir_recursive_absolute(data)
	# the player's settings file the launch finds (the child's user folder is under its XDG_DATA_HOME): medium, chosen
	var user_dir := data.path_join("godot/app_userdata").path_join(String(ProjectSettings.get_setting("application/config/name")))
	DirAccess.make_dir_recursive_absolute(user_dir)
	var settings_file := user_dir.path_join("dm_settings_v2.json")
	var sf := FileAccess.open(settings_file, FileAccess.WRITE)
	sf.store_string('{"graphics":"medium","graphics_chosen":true}')
	sf.close()
	var launch := ["env", "XDG_DATA_HOME=" + data, "XDG_CONFIG_HOME=" + data, OS.get_executable_path(), "--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"), "--"]
	# a QA launch with a tune that is not the data's is refused at once, with exit code 2, before any game is built
	var bad_tune := ProjectSettings.globalize_path(OUT.path_join("launch_bad_tune.json"))
	var bt := FileAccess.open(bad_tune, FileAccess.WRITE)
	bt.store_string('{"combat/abilities": {"abilities": {"haunting_wraith": {"speeed": 5}}}}')
	bt.close()
	var refused: Array = []
	var refused_code := OS.execute(launch[0], launch.slice(1) + ["--dev-offline", "--class=2", "--qa", "--tune=" + bad_tune], refused, true)
	var refused_text := "\n".join(PackedStringArray(refused))
	check(refused_code == 2 and refused_text.contains("QA tune refused: combat/abilities.abilities.haunting_wraith.speeed is not a key of combat/abilities.abilities.haunting_wraith") and not refused_text.contains("QA-SHOTS"),
		"a launch with a tune that names a key the data does not have is refused with exit code 2 and a line saying which (%d)" % refused_code)
	# a clip run on a headless launch, with a tune that is valid and --qa beside --clip-plan= (the agent's launch line has both: the clips win over the scripted fight): the tune is applied and printed, the clips fail for want of a picture, and no file is left
	var clip_plan := ProjectSettings.globalize_path(OUT.path_join("launch_clip_plan.json"))
	var clips := ProjectSettings.globalize_path(OUT.path_join("launch_clips"))
	var good_tune := ProjectSettings.globalize_path(OUT.path_join("launch_tune.json"))
	var cf := FileAccess.open(clip_plan, FileAccess.WRITE)
	cf.store_string('{"clips": [{"name": "a", "cast": "haunting_wraith", "seconds": 2}, {"name": "b", "cast": "scythe_sweep", "at": "ahead", "camera": "wide"}]}')
	cf.close()
	var tf := FileAccess.open(good_tune, FileAccess.WRITE)
	tf.store_string('{"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 5.5}}}}')
	tf.close()
	var made: Array = []
	var made_code := OS.execute(launch[0], launch.slice(1) + ["--dev-offline", "--class=2", "--no-waves", "--qa", "--clip-plan=" + clip_plan, "--clips=" + clips, "--tune=" + good_tune], made, true)
	var made_text := "\n".join(PackedStringArray(made))
	check(made_code == 1 and made_text.contains("QA tune: combat/abilities.abilities.haunting_wraith.speed = 5.5") and made_text.contains("QA-CLIPS clip FAILED " + clips + "/a.mjpeg: no picture") and made_text.contains("QA-CLIPS clip FAILED " + clips + "/b.mjpeg"),
		"a headless clip launch applies and prints its tune, fails each clip for want of a picture and exits 1 (%d)" % made_code)
	check(not made_text.contains("SCRIPT ERROR") and not made_text.contains("Parse Error") and not made_text.contains("QA-CLIPS plan error") and not made_text.contains("QA-CLIPS discipline") and not made_text.contains("QA-SHOTS no game") and not made_text.contains("QA-SHOTS fight"), "with no script error, plan error or missing game, and no scripted fight")
	check(not DirAccess.dir_exists_absolute(clips) or DirAccess.get_files_at(clips).is_empty(), "and no clip file was written")
	var out: Array = []
	var code := OS.execute("env", ["XDG_DATA_HOME=" + data, "XDG_CONFIG_HOME=" + data, OS.get_executable_path(), "--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"), "--",
		"--dev-offline", "--class=2", "--no-waves", "--qa", "--shot-plan=" + plan_file, "--shots=" + shots, "--preset=ultra"], out, true)
	var text := "\n".join(PackedStringArray(out))
	check(code == 1, "a launch with no renderer ends with exit code 1, its pictures missing (%d)" % code)
	check(text.contains("QA-SHOTS shot FAILED " + shots + "/bag.png") and text.contains("QA-SHOTS shot FAILED " + shots + "/hero.png") and text.contains("QA-SHOTS shot FAILED " + shots + "/away.png"), "the boot started the driver, which ran the three shots of the plan")
	check(text.contains("QA-SHOTS no picture:") and not text.contains("QA-SHOTS plan error") and not text.contains("QA-SHOTS equip:") and not text.contains("QA-SHOTS no game"), "and said why, with no plan error, no gear problem and no missing game")
	check(text.contains("QA-SHOTS window did not open: vault (the Vault opens only in the Chapterhouse") and text.count("QA-SHOTS window did not open") == 1, "a window that does not open (the Vault in the Graves) is said, once")
	check(not text.contains("SCRIPT ERROR") and not text.contains("Parse Error"), "no script error in the launch")
	check(DirAccess.get_files_at(shots).is_empty(), "no picture was written")
	check(text.contains("QA-SHOTS preset ultra ") and not text.contains("QA-SHOTS warning"), "the driver says the run has the flag's preset (ultra), with no warning")
	check(text.contains("QA-SHOTS window: takes no focus and passes the mouse through"), "the boot put the QA run's window on no focus and mouse passthrough (the call path: a headless run has no window to configure)")
	# a launch without the QA flags (a debug build reaching its first screen) leaves the window alone
	# the release-safe boot check: the first screen, its line and exit code 0; with --quit-while-loading the loads that quit leaves in flight (a headless run has no renderer to load for: none)
	var boot: Array = []
	var boot_code := OS.execute("env", ["XDG_DATA_HOME=" + data, "XDG_CONFIG_HOME=" + data, OS.get_executable_path(), "--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"), "--",
		"--dev-offline", "--boot-check"], boot, true)
	var boot_text := "\n".join(PackedStringArray(boot))
	var boot_re := RegEx.create_from_string("(?m)^BOOT OK (\\d+)$")
	var boot_hit := boot_re.search(boot_text)
	check(boot_code == 0 and boot_hit != null and int(boot_hit.get_string(1)) > 0 and boot_text.contains("BOOT screen ") and not boot_text.contains("QUIT-WHILE-LOADING") and not boot_text.contains("SCRIPT ERROR"),
		"--boot-check reaches the first screen, prints BOOT OK <ms> and quits with exit code 0 (%d)" % boot_code)
	var quit_load: Array = []
	var quit_code := OS.execute("env", ["XDG_DATA_HOME=" + data, "XDG_CONFIG_HOME=" + data, OS.get_executable_path(), "--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"), "--",
		"--dev-offline", "--boot-check", "--quit-while-loading"], quit_load, true)
	var quit_text := "\n".join(PackedStringArray(quit_load))
	check(quit_code == 0 and quit_text.contains("BOOT OK ") and quit_text.contains("QUIT-WHILE-LOADING 0 of 0 loads in flight") and not quit_text.contains("SCRIPT ERROR"), "--boot-check --quit-while-loading quits 0 after saying how many loads were in flight (%d)" % quit_code)
	var alone: Array = []
	OS.execute("env", ["XDG_DATA_HOME=" + data, "XDG_CONFIG_HOME=" + data, OS.get_executable_path(), "--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"), "--",
		"--dev-offline", "--boot-smoke", "--quit-while-loading"], alone, true)
	var alone_text := "\n".join(PackedStringArray(alone))
	check(alone_text.contains("BOOT OK ") and not alone_text.contains("QUIT-WHILE-LOADING") and not alone_text.contains("BOOT screen"), "--quit-while-loading is read only with --boot-check")
	var plain: Array = []
	var plain_code := OS.execute("env", ["XDG_DATA_HOME=" + data, "XDG_CONFIG_HOME=" + data, OS.get_executable_path(), "--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"), "--",
		"--dev-offline", "--boot-smoke", "--preset=low", "--tune=" + bad_tune, "--clips=" + clips], plain, true)
	var plain_text := "\n".join(PackedStringArray(plain))
	check(plain_code == 0 and plain_text.contains("BOOT OK") and not plain_text.contains("QA-SHOTS") and not plain_text.contains("QA tune") and not plain_text.contains("QA-CLIPS"),
		"a launch without --qa, --shot-plan= or --clip-plan= starts none of it (no window line, no preset, no tune, even with --preset=, --tune= and --clips= and a tune that would be refused): it reaches its first screen (%d)" % plain_code)
	check(FileAccess.file_exists(user_dir.path_join("dm_dev_offline_db.json")), "(the launch's user folder is the one the settings file was put in: its offline backend saved there)")
	check(FileAccess.file_exists(settings_file) and FileAccess.get_file_as_string(settings_file) == '{"graphics":"medium","graphics_chosen":true}', "and the player's settings file is as the launch found it: nothing was saved")


# ------------------------------------------------------------------------------------------------------------------ the script

func script_flow() -> void:
	var tools_ok := OS.execute("bash", ["-c", "command -v xvfb-run Xvfb xauth flock python3 timeout mktemp realpath > /dev/null && xvfb-run -a true"]) == 0
	if not tools_ok:
		print("INFO qa_shots: tools/qa_shots.sh is not run here (xvfb-run with Xvfb and xauth, flock or python3 is missing, or no X server starts)")
		return
	var dir := ProjectSettings.globalize_path(OUT.path_join("script"))
	DirAccess.make_dir_recursive_absolute(dir)
	var fake := ProjectSettings.globalize_path("res://tests/qa_shots_fake_godot.sh")   # a stand-in for godot: records how it was started, answers as a renderer would
	OS.execute("chmod", ["+x", fake])
	var script := ProjectSettings.globalize_path("res://tools/qa_shots.sh")
	for name in ["plan.json", "reaper.json", "bad.json"]:
		var pf := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
		pf.store_string('{"shots": [{}]}' if name == "plan.json" else ('{"discipline": "reaper", "shots": [{}]}' if name == "reaper.json" else "not a plan"))
		pf.close()
	var icd := dir.path_join("lvp_icd.json")
	var ip := FileAccess.open(icd, FileAccess.WRITE)
	ip.store_string("{}")
	ip.close()

	# Forward+ on lavapipe: the launch line, the scratch user folder, the renderer lock held, nice 10, no fallback line
	var r := run_script(dir, script, "ok", [dir.path_join("plan.json"), dir.path_join("pics-ok")], icd)
	check(r["code"] == 0 and (r["text"] as String).contains("rendering with vulkan") and not (r["text"] as String).contains("fallback renderer (OpenGL"), "the script renders on Vulkan (exit %d)" % r["code"])
	check((r["text"] as String).contains("renderer: Vulkan 1.3.255 - Forward+") and (r["text"] as String).contains("1 picture(s) in " + dir.path_join("pics-ok") + ", rendered with Vulkan Forward+ (software, lavapipe)"), "and says which renderer made the pictures")
	check(FileAccess.file_exists(dir.path_join("pics-ok/a.png")) and (r["text"] as String).contains("QA-SHOTS shot " + dir.path_join("pics-ok/a.png")), "the pictures are in the out folder and the game's lines are shown")
	var calls := _lines(dir.path_join("calls-ok/calls.txt"))
	check(calls.size() == 1 and calls[0].begins_with("--rendering-method forward_plus --rendering-driver vulkan --path ") and calls[0].ends_with(" -- --dev-offline --class=2 --qa --shot-plan=%s --shots=%s" % [dir.path_join("plan.json"), dir.path_join("pics-ok")]),
		"godot is started with Forward+ on Vulkan and the dev-offline QA line (%s)" % str(calls))
	var env := _lines(dir.path_join("calls-ok/env.txt"))
	var parts: PackedStringArray = env[0].split("|") if not env.is_empty() else PackedStringArray(["", "", ""])
	check(parts[0] == icd and parts[1].begins_with("/tmp/dm-qa-shots.") and int(parts[2]) >= 10, "under the lavapipe ICD, a scratch user folder and nice 10 or more (%s)" % str(env))
	check(_lines(dir.path_join("calls-ok/lock.txt")) == ["held"], "while the renderer lock is held")
	check(not DirAccess.dir_exists_absolute(parts[1].get_base_dir()), "the scratch folder is gone after the run")
	# the plan's discipline picks the class, a class on the line wins
	var rr := run_script(dir, script, "ok", [dir.path_join("reaper.json"), dir.path_join("pics-reaper")], icd)
	check(rr["code"] == 0 and _lines(dir.path_join("calls-reaper/calls.txt"))[0].contains("--class=11 "), "the plan's discipline (reaper) is class 11")
	var rc := run_script(dir, script, "ok", [dir.path_join("reaper.json"), dir.path_join("pics-reaper2"), "4"], icd)
	check(rc["code"] == 0 and _lines(dir.path_join("calls-reaper2/calls.txt"))[0].contains("--class=4 "), "a class on the command line wins")
	# a caller that holds the lock already (the agent's sandbox) is not made to wait for it again
	var lk := run_script(dir, script, "ok", [dir.path_join("plan.json"), dir.path_join("pics-locked")], icd, "DM_QA_LOCKED=1")
	check(lk["code"] == 0 and not (lk["text"] as String).contains("waiting for the renderer lock") and _lines(dir.path_join("calls-locked/lock.txt")) == ["free"], "DM_QA_LOCKED=1: the lock is not taken again")
	# Vulkan cannot start: the fallback, said in a line, on OpenGL 3
	var fb := run_script(dir, script, "novulkan", [dir.path_join("plan.json"), dir.path_join("pics-fb")], icd)
	var ft: String = fb["text"]
	check(fb["code"] == 0 and ft.contains("qa_shots: Vulkan could not start") and ft.contains("the pictures use the fallback renderer (OpenGL 3, Compatibility)"), "when Vulkan cannot start the script says the pictures use the fallback renderer (exit %d)" % fb["code"])
	check(ft.contains("rendered with OpenGL 3 Compatibility (the fallback renderer)") and FileAccess.file_exists(dir.path_join("pics-fb/a.png")), "and takes them on OpenGL 3")
	var fcalls := _lines(dir.path_join("calls-fb/calls.txt"))
	check(fcalls.size() == 2 and fcalls[1].begins_with("--rendering-method gl_compatibility --rendering-driver opengl3 --path"), "the second start is OpenGL 3 on the Compatibility renderer (%s)" % str(fcalls))
	# godot goes to OpenGL 3 on its own: the pictures are labelled as the fallback's all the same
	var sf := run_script(dir, script, "selffall", [dir.path_join("plan.json"), dir.path_join("pics-sf")], icd)
	check(sf["code"] == 0 and (sf["text"] as String).contains("the pictures use the fallback renderer (godot started on its own without Vulkan Forward+)") and (sf["text"] as String).contains("rendered with a fallback renderer") and _lines(dir.path_join("calls-sf/calls.txt")).size() == 1,
		"a renderer godot chose itself is said to be the fallback, after one start (exit %d)" % sf["code"])
	# the driver is not installed: no Vulkan start at all
	var ni := run_script(dir, script, "ok", [dir.path_join("plan.json"), dir.path_join("pics-ni")], dir.path_join("no-such-icd.json"))
	check(ni["code"] == 0 and (ni["text"] as String).contains("lavapipe) is not installed") and (ni["text"] as String).contains("the pictures use the fallback renderer") and _lines(dir.path_join("calls-ni/calls.txt")).size() == 1, "without lavapipe it goes straight to the fallback")
	# Vulkan ran and a shot failed: that is not a renderer problem, no second try
	var fs := run_script(dir, script, "failshot", [dir.path_join("plan.json"), dir.path_join("pics-fs")], icd)
	check(fs["code"] == 1 and not (fs["text"] as String).contains("fallback renderer") and _lines(dir.path_join("calls-fs/calls.txt")).size() == 1 and (fs["text"] as String).contains("godot exited 1"), "a failed shot on Vulkan is reported, not retried (exit %d)" % fs["code"])
	# the time limit: the run is ended, the scratch folder goes, the exit code says it
	var sl := run_script(dir, script, "slow", [dir.path_join("plan.json"), dir.path_join("pics-slow")], icd, "DM_QA_LIMIT=2")
	var slow_env := _lines(dir.path_join("calls-slow/env.txt"))
	var sparts: PackedStringArray = String(slow_env[0] if not slow_env.is_empty() else "||").split("|")
	check(sl["code"] == 124 and (sl["text"] as String).contains("timed out after 2 seconds"), "past its time limit the run is ended with exit code 124 (%d)" % sl["code"])
	check(not DirAccess.dir_exists_absolute(sparts[1].get_base_dir()), "and its scratch folder is gone")
	# bad arguments never start anything
	var b1 := run_script(dir, script, "ok", [dir.path_join("no-plan.json"), dir.path_join("pics-b1")], icd)
	var b2 := run_script(dir, script, "ok", [dir.path_join("plan.json"), dir.path_join("pics-b2"), "gravecaller"], icd)
	var b3 := run_script(dir, script, "ok", [], icd)
	check(b1["code"] == 2 and (b1["text"] as String).contains("no plan file") and b2["code"] == 2 and (b2["text"] as String).contains("the class must be a number") and b3["code"] == 2, "a missing plan, a class that is no number and no arguments are refused with exit code 2")
	check(not FileAccess.file_exists(dir.path_join("calls-b1/calls.txt")) and not FileAccess.file_exists(dir.path_join("calls-b2/calls.txt")), "and godot is not started for them")


## Runs tools/qa_shots.sh with the stand-in for godot in `mode`; its records go to <dir>/calls-<out name without "pics-">/. `extra`: more environment ("NAME=value").
func run_script(dir: String, script: String, mode: String, args: Array, icd: String, extra := "") -> Dictionary:
	var tag := String(args[1]).get_file().trim_prefix("pics-") if args.size() > 1 else "none"
	var rec := dir.path_join("calls-" + tag)
	DirAccess.make_dir_recursive_absolute(rec)
	var line := ["env", "GODOT=" + ProjectSettings.globalize_path("res://tests/qa_shots_fake_godot.sh"), "DM_BROWSER_LOCK=" + dir.path_join("lock"), "DM_QA_ICD=" + icd, "FAKE_MODE=" + mode, "FAKE_DIR=" + rec]
	if extra != "":
		line.append(extra)
	line.append_array(["bash", script])
	line.append_array(args)
	var out: Array = []
	var code := OS.execute(line[0], line.slice(1), out, true)
	return {"code": code, "text": "\n".join(PackedStringArray(out))}


func _lines(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var out := []
	for l in FileAccess.get_file_as_string(path).split("\n"):
		if String(l).strip_edges() != "":
			out.append(String(l).strip_edges())
	return out


func _remove_tree(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		OS.execute("rm", ["-rf", path])
