extends SceneTree
## The screenshot tool of proposals on the game (client/README.md "Screenshots for proposals"), headless and without a renderer. The tool is the QA driver (main/qa_driver.gd), the shot plan
## (main/qa_ui_shots.gd) and the script that renders a plan (tools/qa_shots.sh); the boot starts the driver (main/main.gd `start_qa`). It checks:
##   - the plan: today's format parses (names, windows and their aliases, hover, clip, wait cap, at most 4 shots, equip cap, discipline by name or number, view, turn and anim), what it refuses, every window id a real
##     panel of the HUD, the demo bag's items exist and fit, the discipline table agrees with the content's, with `--class=N` and with tools/qa_shots.sh, and the crop of "clip": "window" in numbers;
##   - the boot's hook: the QA tools start for `--qa` or `--shot-plan=` on the dev-offline backend of a debug build only (a release export and an online start never), as the child Driver of the boot;
##   - the set-up a plan asks for, on the game scene with a dev character on the local mock (never a server): the demo bag and the "give" items in the bag, the "equip" gear worn through the backend's equip call
##     (an unknown id and an item that cannot be worn skipped), the hero's look and the set look at three pieces, the hero healed; per shot the windows (the Reliquary and its tooltip of an item, the Vault in the
##     Chapterhouse), the area the hero stands in, the game view (HUD hidden) and the hero close-up (HUD and windows away, the close-up camera, the turn, the pose frozen) and all of it put back after the picture;
##   - the scripted fight of the driver on the combat core: a pack of the dead arrives (through the core, as ids) and the rites are cast at the nearest one;
##   - a QA run takes no focus and no mouse (`DmMain.quiet_window`: the main window's `unfocusable` and `mouse_passthrough`): the flags on a window of its own, and in a real launch the boot's line saying it asked for them
##     (a headless run has no window to configure, so only the call path is tested), and none from a launch without the QA flags;
##   - a real launch (`godot --headless -- --dev-offline --class=2 --qa --shot-plan=... --preset=ultra`): the boot starts the driver, which runs the plan, says the run's preset and that there is no picture to take without a renderer,
##     and leaves the settings file it found as it was;
##   - `--preset=<low|medium|high|ultra>`: honoured only where the QA tools start (`DmMain.qa_preset`: not online, not in a release build, not without --qa or --shot-plan=), an unknown value ignored with a warning; the
##     game scene starts with that preset (the HUD's settings too) and DmSettings holds it on loan: never written to the player's file, written back as the player stored it, an explicit different choice saved as usual;
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
	crop()
	boot_hook()
	await scene_setup()
	await scripted_fight()
	settings_loan()
	await preset_on_game()
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
	check(DmQaUiShots.parse('{"shots":[{},{},{},{},{},{}]}')["shots"].size() == DmQaUiShots.MAX_SHOTS and DmQaUiShots.MAX_SHOTS == 4, "at most 4 shots")
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
	var win := Window.new()   # a window of its own: the flags a QA run puts on the main window, read back from the node (a headless display server has none to read)
	check(not win.unfocusable and not win.mouse_passthrough, "a window takes focus and the mouse by default")
	DmMain.quiet_window(win)
	check(win.unfocusable and win.mouse_passthrough, "the QA run's window takes no focus and passes the mouse through")
	DmMain.quiet_window(null)
	win.free()
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
	var plain: Array = []
	var plain_code := OS.execute("env", ["XDG_DATA_HOME=" + data, "XDG_CONFIG_HOME=" + data, OS.get_executable_path(), "--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"), "--",
		"--dev-offline", "--boot-smoke", "--preset=low"], plain, true)
	var plain_text := "\n".join(PackedStringArray(plain))
	check(plain_code == 0 and plain_text.contains("BOOT OK") and not plain_text.contains("QA-SHOTS"), "a launch without --qa or --shot-plan= starts none of it (no window line, no preset, even with --preset=): it reaches its first screen (%d)" % plain_code)
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
