extends SceneTree
## The shipped entry flow (owner 2026-10-09 baseline: one online game, necromancers only, offline edition retired), headless, on the
## dev-offline backend so it never touches the live server:
##   launch args -> mode (online unless a testing flag), the offline edition's save + "offline:" token wiped on an online start,
##   main scene -> login -> discipline select (4 necromancer cards open, the other 5 greyed out and refused) -> the game (DmNextGame),
##   a character of a discipline that is not playable yet -> the discipline switch -> change_discipline -> the game, with its level kept.
## godot --headless --path godot --script res://tests/game/flow_run.gd

var _pass := 0
var _fail := 0

func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)

func _initialize() -> void:
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n:
		await process_frame

## Poll a condition on the wall clock (one frame apart): a frame-count cap flaked when threaded loads lag on a loaded VPS.
func _until(cond: Callable, sec: float) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end and not cond.call():
		await process_frame

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f = null

func _run() -> void:
	# ---- launch args: one online game; only testing flags reach the local backend
	_check(DmMain.mode_for(PackedStringArray()) == "online", "no args = online")
	_check(DmMain.mode_for(PackedStringArray(["--offline"])) == "online", "an old launcher's --offline starts online")
	_check(DmMain.mode_for(PackedStringArray(["--online", "--next"])) == "online", "--online / --next = online")
	_check(DmMain.mode_for(PackedStringArray(["--dev-offline"])) == "dev_offline", "--dev-offline = the testing backend")
	_check(DmMain.DEV_OFFLINE_DB != DmMain.OFFLINE_EDITION_DB, "dev-offline never reuses the player's old offline save")
	# ---- the retired offline edition is wiped (its save, its tmp file and an "offline:" token); an online token is kept
	_write(DmMain.OFFLINE_EDITION_DB, "{}")
	_write(DmMain.OFFLINE_EDITION_DB + ".tmp", "{}")
	_write(DmApi.TOKEN_FILE, "offline:olduser")
	DmMain.wipe_offline_edition()
	_check(not FileAccess.file_exists(DmMain.OFFLINE_EDITION_DB) and not FileAccess.file_exists(DmMain.OFFLINE_EDITION_DB + ".tmp"), "offline edition save deleted")
	_check(not FileAccess.file_exists(DmApi.TOKEN_FILE), "offline session token deleted")
	_write(DmApi.TOKEN_FILE, "aaa.bbb.ccc")
	DmMain.wipe_offline_edition()
	_check(FileAccess.file_exists(DmApi.TOKEN_FILE), "an online session token is kept")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DmApi.TOKEN_FILE))
	# ---- playable disciplines
	var necro := 0
	for d in DmCharSelectScreen.load_disciplines():
		var fam := String(DmCharacterBuild.discipline_for(float(d["classIndex"]))["family"])
		_check(DmCharacterBuild.is_playable(float(d["classIndex"])) == (fam == "necromancer"), "%s playable only if necromancer" % d["id"])
		if fam == "necromancer":
			necro += 1
	_check(necro == 4, "four playable disciplines (%d)" % necro)
	# ---- main scene: login -> select
	var main: DmMain = load("res://main/main.tscn").instantiate()
	main.mode = "dev_offline"
	main.persist_token = false
	root.add_child(main)
	await _frames(10)
	await _until(func() -> bool: return main.flow != null and main.flow.current_name == "login", 30.0)
	_check(main.flow != null and main.flow.current_name == "login", "the login screen shows first: %s" % (main.flow.current_name if main.flow != null else "-"))
	var uname := "flow%d" % (Time.get_ticks_usec() % 1000000)
	var r := await main.api.register(uname, "f@example.com", "pw1234")
	_check(r.ok, "registered")
	main.api.set_token(r.data["token"])
	await main.flow.resume()
	_check(main.flow.current_name == "select", "a new account goes to discipline select: %s" % main.flow.current_name)
	var sel: DmCharSelectScreen = main.flow.current as DmCharSelectScreen
	var locked := 0
	for c in sel.cards:
		var playable := DmCharacterBuild.is_playable(float(c.disc["classIndex"]))
		_check(c.locked == not playable and (c.disabled or playable), "%s card %s" % [c.disc["id"], "open" if playable else "greyed out"])
		if c.locked:
			locked += 1
	_check(locked == 5, "five greyed-out cards (%d)" % locked)
	_check(not await sel.choose(5) and main.flow.current_name == "select", "a greyed-out discipline is refused")
	var gr := await main.api.get_character()
	_check(gr.status == 404, "refusing created no character")
	# ---- a character of a discipline that is not playable yet (an existing online one): resume -> the discipline switch
	var c5 := await main.api.load_or_create_character(5)
	_check(c5.ok and int(c5.data["class_index"]) == 5, "an old Grave Warden character exists")
	await main.flow.resume()
	sel = main.flow.current as DmCharSelectScreen
	_check(main.flow.current_name == "select" and sel != null and not sel.switching.is_empty(), "resume offers the discipline switch")
	_check(main.slice == null and main.game == null, "no game built for an unplayable discipline")
	if sel != null:
		await sel.choose(2)
	await _until(func() -> bool: return main.slice != null and main.slice.ready_ and DmLoadingScreen.current == null, 60.0)
	_check(main.slice != null and main.slice.ready_, "after the switch the game is up")
	if main.slice != null:
		var ch: Dictionary = main.slice.character
		_check(int(ch["class_index"]) == 2 and int(ch["id"]) == int(c5.data["id"]), "same character, now a Gravecaller (%s)" % ch.get("class_index"))
		_check(main.game == null, "the old DmGame is not built")
		_check(DmMain.token_username("offline:" + uname) == uname, "token username")
		main.slice.ui_host.leave_world()
	await _until(func() -> bool: return main.slice == null and main.flow != null and main.flow.current_name == "login", 30.0)
	_check(main.slice == null and main.flow != null, "Leave returns to the login screen")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
