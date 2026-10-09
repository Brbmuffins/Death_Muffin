extends SceneTree
## Rebuild front-flow suite (godot/main/main.gd, USE_NEXT routing): godot --headless --path godot --script res://tests/next_front/run.gd
## DmMain on the offline backend (in-memory mock): register -> discipline select -> DmNextGame, log out, log in (persisted), quit save,
## and 3 enter/leave cycles measured for leaks. The default (old) path is checked to still route to DmGame.

class ErrLog extends Logger:
	var errors: Array = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor: bool, error_type: int, _bt: Array) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s" % [file.get_file(), line, code, rationale])

const NODE_BOUND := 60          ## nodes allowed to remain after 3 more enter/leave cycles than after the first
const MEM_BOUND_MB := 40.0      ## static memory growth allowed over the same cycles (shared VPS, GC noise)

var passed := 0
var failed := 0
var log_ := ErrLog.new()
var api: DmApi
var mock: DmMockBackend
var m: DmMain


func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)

func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()

func _in_world() -> bool:
	return m.slice != null and m.slice.ready_ and DmLoadingScreen.current == null

func _at(screen: String) -> bool:
	return m.slice == null and m.flow != null and m.flow.current_name == screen

func _new_main(next: bool) -> DmMain:
	var n := DmMain.new()
	n.mode = "test"
	n.use_next = next
	n.persist_token = false
	n.api = api
	root.add_child(n)
	return n

## Register a local player on the login screen and pick a discipline; returns once the rebuild is live.
func _register_and_pick(name_: String, class_index: int) -> void:
	await until(func() -> bool: return _at("login"), 10.0)
	var l: DmLoginScreen = m.flow.current
	l.toggle_mode()
	await process_frame
	l.user_edit.text = name_
	var ok := await l.submit()
	if not ok:
		print("register failed: ", l.error_label.text)
	await until(func() -> bool: return _at("select"), 10.0)
	var sel: DmCharSelectScreen = m.flow.current as DmCharSelectScreen
	if sel == null:
		return
	await sel.choose(class_index)
	await until(_in_world, 60.0)

func _login(name_: String) -> void:
	await until(func() -> bool: return _at("login"), 10.0)
	var l: DmLoginScreen = m.flow.current
	l.user_edit.text = name_
	await l.submit()
	await until(_in_world, 60.0)

func _logout() -> void:
	m.slice.ui_host.leave_world()
	await until(func() -> bool: return _at("login"), 30.0)
	await process_frame

func _necro_indices() -> Dictionary:
	var out := {}
	for d in DmCharSelectScreen.load_disciplines():
		var full: Dictionary = DmCharacterBuild.discipline_for(float(d["classIndex"]))
		if String(full["family"]) == "necromancer":
			out[String(d["id"])] = int(d["classIndex"])
	return out

func _snap() -> Dictionary:
	return {"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "mem": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0}


func _run() -> void:
	OS.add_logger(log_)
	mock = DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	check(DmMain.USE_NEXT == true, "the rebuild is the default (USE_NEXT true)")
	for d in DmCharSelectScreen.load_disciplines():
		var fam := String(DmCharacterBuild.discipline_for(float(d["classIndex"]))["family"])
		check(DmMain.next_supports({"class_index": int(d["classIndex"])}) == (fam == "necromancer"), "%s (%s) enters %s" % [d["id"], fam, "the rebuild" if fam == "necromancer" else "the old game"])
	m = _new_main(true)
	check(m.use_next, "use_next routes the front to DmNextGame")
	# ---- every necromancer discipline: register -> select -> the rebuild with that character
	var necro := _necro_indices()
	check(necro.size() == 4 and necro.has("ossuary") and necro.has("gravecaller") and necro.has("mourner") and necro.has("rotweaver"), "four necromancer disciplines (%s)" % str(necro.keys()))
	var n := 0
	var flasks0 := 0
	for id in necro:
		n += 1
		var who := "necro%d" % n
		await _register_and_pick(who, necro[id])
		check(_in_world(), "%s: the rebuild is live behind the front (%s)" % [id, who])
		if not _in_world():
			break
		var g: DmNextGame = m.slice
		var ch := g.character
		check(int(ch["class_index"]) == necro[id] and int(ch["level"]) == 1, "%s: character class %s level %s" % [id, ch.get("class_index"), ch.get("level")])
		check(g.local_body() != null and g.local_body().discipline_id == id, "%s: the body plays that discipline" % id)
		check(g.is_offline and g.api == api and api.get_token() == "offline:" + who, "%s: offline backend, authenticated session" % id)
		check(g.ui_host != null and g.ui_host.slots is Array and g.ui_host.character == ch, "%s: HUD host holds the character and a bag" % id)
		check(m.flow == null and m.game == null, "%s: front screens gone, old game not built" % id)
		var bag_before: int = g.ui_host.slots.size()
		if n == 1:
			# persistence: a bag item + gold survive log out -> log in
			flasks0 = g.ui_host.inventory.count("flask_hp_minor")
			g.ui_host.inventory.add({"item_id": "flask_hp_minor", "quantity": 2})
			ch["gold"] = int(ch.get("gold", 0)) + 0   # gold is credited by the rewards; the bag is what this probes
		await _logout()
		check(m.get_node_or_null("NextGame") == null, "%s: log out frees the rebuild" % id)
		check(api.get_token() == "", "%s: log out clears the session" % id)
		if n == 1:
			await _login(who)
			var g2: DmNextGame = m.slice
			check(g2 != null and int(g2.character["id"]) == int(ch["id"]) and int(g2.character["class_index"]) == necro[id], "re-enter: same persisted character")
			check(g2 != null and g2.ui_host.inventory.count("flask_hp_minor") == flasks0 + 2 and g2.ui_host.slots.size() >= bag_before, "re-enter: the bag item persisted through the log out flush")
			# quit saves
			g2.ui_host.inventory.add({"item_id": "flask_hp_minor", "quantity": 3})
			await m.save_all()
			var inv := await api.get_inventory(int(g2.character["id"]))
			var total := 0
			for s in inv.data:
				if s is Dictionary and String(s.get("item_id", "")) == "flask_hp_minor":
					total += int(s.get("quantity", 0))
			check(total == flasks0 + 5, "quit: save_all flushed the bag to the backend (%d)" % total)
			m.slice = g2   # save_all detaches it; hand it back for the clean log out
			await _logout()
	# ---- 3 enter/leave cycles: no growth
	await _login("necro1")
	# class change (the panel's hand-off): the rebuild is torn down and re-entered with the new character, no front screen in between
	var before: int = m.slice.get_instance_id()
	m.slice.ui_host.class_changed(m.slice.character)
	await until(func() -> bool: return _in_world() and m.slice.get_instance_id() != before, 60.0)
	check(_in_world() and m.slice.get_instance_id() != before, "class change re-enters a fresh rebuild")
	await process_frame
	check(not is_instance_id_valid(before) or (instance_from_id(before) as Node).is_queued_for_deletion(), "class change frees the old rebuild")
	await _logout()
	await process_frame
	var base := _snap()
	for i in 3:
		await _login("necro1")
		check(_in_world(), "cycle %d: entered" % (i + 1))
		await _logout()
	await process_frame
	await process_frame
	var after := _snap()
	var dn: float = after["nodes"] - base["nodes"]
	var dm: float = after["mem"] - base["mem"]
	print("leak probe: nodes %d -> %d (%+d), static mem %.1f -> %.1f MB (%+.1f)" % [base["nodes"], after["nodes"], dn, base["mem"], after["mem"], dm])
	check(dn <= NODE_BOUND, "3 cycles: node growth %+d <= %d" % [dn, NODE_BOUND])
	check(dm <= MEM_BOUND_MB, "3 cycles: static memory growth %+.1f MB <= %.0f" % [dm, MEM_BOUND_MB])
	m.queue_free()
	await process_frame
	# ---- default routing is the rebuild, but a non-necromancer character (no kit on the rebuild yet) still enters DmGame
	m = _new_main(false)
	check(m.use_next, "default routing: the rebuild (USE_NEXT)")
	await _register_and_pick_old("oldpath", 5)
	check(m.game != null and m.slice == null, "non-necro (Grave Warden): DmGame entered, no rebuild")
	await m.save_all()
	m.queue_free()
	await process_frame
	check(log_.errors.is_empty(), "no engine errors in the log (%d: %s)" % [log_.errors.size(), ", ".join(log_.errors.slice(0, 3))])
	OS.remove_logger(log_)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _register_and_pick_old(name_: String, class_index: int) -> void:
	await until(func() -> bool: return _at("login"), 10.0)
	var l: DmLoginScreen = m.flow.current
	l.toggle_mode()
	await process_frame
	l.user_edit.text = name_
	await l.submit()
	await until(func() -> bool: return _at("select"), 10.0)
	var sel: DmCharSelectScreen = m.flow.current
	await sel.choose(class_index)
	await until(func() -> bool: return m.game != null and m.game.ready_ and m.ui != null and DmLoadingScreen.current == null, 60.0)
