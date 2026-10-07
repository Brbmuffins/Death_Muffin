extends SceneTree
## OPT-IN live check of the rebuild's ONLINE solo path against the PRODUCTION Death Muffin backend, with the QA account qa_offline_sync only
## (never any other account; no account is created). Skipped (exit 0) unless DM_LIVE_ONLINE=1 and DM_QA_PASS_FILE names a file holding the
## QA password, so run-all-tests.sh and CI never touch prod:
##   DM_LIVE_ONLINE=1 DM_QA_PASS_FILE=<file> godot --headless --path godot --script res://tests/online_live/run.gd
## Walks: login -> existing character -> DmNextGame (online api) -> area entry -> kills (session or kill-ledger credit) -> server-rolled loot ->
## gold / xp saves -> bag save -> a server-priced spend (spend_on_server) -> session end -> relog -> everything persisted.
## Traffic is a few dozen requests (no polling loops). Secrets are never printed.

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var skipped := 0
var tr: DmHttpTransport
var api: DmApi
var g: DmNextGame
var pw := ""
var notes: Array = []


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func skip(what: String) -> void:
	skipped += 1
	print("SKIP: ", what)


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func login() -> bool:
	if tr == null:
		tr = DmHttpTransport.new()
		root.add_child(tr)
		await process_frame
	api = DmApi.new(tr.request_callable())
	api.slot_decorator = Callable(DmAffixes, "decorate_slots")
	var l := await api.login("qa_offline_sync", pw)
	if not (l.ok and l.data is Dictionary and l.data.get("token") is String):
		check(false, "login: " + l.error)
		return false
	api.set_token(l.data["token"])
	return true


func launch(c: Dictionary) -> void:
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c, api, {"offline": false, "dressing": false, "persist": false, "waves": false, "audio": false, "name": "qa_offline_sync"})


## Leave the world (saves everything, ends the session); true when the rewards' session / ledger was closed.
func close() -> bool:
	await g.leave()
	var ended: bool = g.rewards.ended
	g.queue_free()
	await process_frame
	return ended


func _run() -> void:
	if OS.get_environment("DM_LIVE_ONLINE") != "1":
		print("online_live: skipped (set DM_LIVE_ONLINE=1 and DM_QA_PASS_FILE to run against the live backend)")
		quit(0)
		return
	var pf := OS.get_environment("DM_QA_PASS_FILE")
	if pf.is_empty() or not FileAccess.file_exists(pf):
		print("online_live: skipped (DM_QA_PASS_FILE missing)")
		quit(0)
		return
	pw = FileAccess.get_file_as_string(pf).strip_edges()
	DmSimData.ensure()
	await _walk()
	print("online_live: %d passed, %d failed, %d skipped" % [passed, failed, skipped])
	for n in notes:
		print("  note: ", n)
	quit(1 if failed > 0 else 0)


func _walk() -> void:
	# ---- login + the existing character (D8) -------------------------------------------------------------------------------------------
	if not await login():
		return
	var cr := await api.get_character()
	check(cr.ok and cr.data is Dictionary and int(cr.data.get("id", 0)) > 0, "existing character loads (D8): " + cr.error)
	if not cr.ok:
		return
	var c0: Dictionary = cr.data
	var cid := int(c0["id"])
	var cls := int(c0["class_index"])
	var again := await api.load_or_create_character(cls)   # what the character card does for an existing character
	check(again.ok and int(again.data.get("id", 0)) == cid, "picking the card returns the same character, not a new one")
	var inv0 := await api.get_inventory(cid)
	check(inv0.ok and inv0.data is Array, "bag loads")
	var bag0 := (inv0.data as Array).size() if inv0.ok else 0
	var necro0 := await api.necro_get(cid)
	check(necro0.ok, "necro progress loads: " + necro0.error)
	var kills0 := int(necro0.data["progress"].get("totalKills", 0)) if necro0.ok else 0
	var xp0 := int(c0.get("experience", 0))
	var gold0 := int(c0.get("gold", 0))
	var lvl0 := int(c0.get("level", 1))

	# ---- the rebuild on the live backend ------------------------------------------------------------------------------------------------
	await launch(c0)
	check(g.is_offline == false and g.api == api, "DmNextGame runs on the live api")
	check(g.progress != null and g.progress.prog.mode == "server", "progression adopted the server's necro state")
	var m: DmRewardsMember = g.rewards.members.get(cid)
	check(m != null and m.api == api, "host rewards member carries the live api")
	await until(func() -> bool: return g.rewards.session_id != "" or g.rewards.legacy_ledger, 10.0)
	var via_session: bool = g.rewards.session_id != ""
	notes.append("kill credit path: " + ("host session (/api/sessions)" if via_session else "kill-ledger fallback (/api/kills/report; /api/sessions not deployed)"))
	check(via_session or g.rewards.legacy_ledger, "a credit path is open (session or ledger fallback)")
	if via_session:
		check(g.rewards.session_id.length() == 32, "host session opened on the live backend (migration 041 applied)")
	else:
		skip("host session open / report / end: needs migration 041 (server/death-muffin/backend/migrations/041-party-sessions.sql + party-sessions.cjs)")
	# area entry
	var areas_seen: Array = []
	g.area_changed.connect(func(id: String) -> void: areas_seen.append(id))
	g.chapterhouse.travel("graves")
	await until(func() -> bool: return g.area_id == "graves", 5.0)
	check(g.area_id == "graves" and g.rewards.area_id == "graves", "entering the Graves moves the hero and the rewards area")

	# ---- kills -> credit + server-rolled loot ---------------------------------------------------------------------------------------------
	var body := g.local_body()
	g.rewards.rng = func() -> float: return 0.0   # every chance hits: gear drops (rolled by the server), shards, gold
	var credited: Array = []
	var dropped: Array = []
	g.rewards.loot_dropped.connect(func(_c: int, d: Dictionary, _p: Vector3) -> void: dropped.append(d))
	g.rewards.member_credited.connect(func(_c: int, d: Dictionary) -> void: credited.append(d))
	for i in 8:
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": i % 4 == 0, "x": body.position.x, "z": body.position.z, "killer": body})
	await g.rewards.flush()
	check(not credited.is_empty() and int(credited[0]["kills"]) > 0, "kills credited by the backend reply: %s" % [credited])
	check(g.progress.prog.character["experience"] > xp0 or g.progress.prog.character["level"] > lvl0, "XP applied from the accepted report")
	check(int(g.progress.prog.local["totalKills"]) >= kills0 + 1, "kill counts applied")
	await until(func() -> bool: return g.rewards.gear_pending() == 0, 20.0)
	var gear := dropped.filter(func(d: Dictionary) -> bool: return DmAffixes.can_roll(String(d.get("item_id", ""))))
	var rolled := gear.filter(func(d: Dictionary) -> bool: return d.get("instance") != null)
	check(not gear.is_empty() and rolled.size() == gear.size(), "every gear drop carries the server's roll (%d of %d; %d drops in all)" % [rolled.size(), gear.size(), dropped.size()])
	# pick everything up: gold / shards / items by standing on them
	await until(func() -> bool: return m.loot_view.count() == 0, 15.0)
	check(m.loot_view.count() == 0 or m.stats["items_picked"] > 0, "loot picked up by walking over it (%d left)" % m.loot_view.count())
	var gold_now := int(g.progress.prog.character["gold"])
	check(gold_now > gold0, "gold picked up (%d -> %d)" % [gold0, gold_now])

	# ---- saves: character, necro, bag ----------------------------------------------------------------------------------------------------
	var err := await g.progress.flush_all()
	check(err == "", "progress saved: " + err)
	await g.ui_host.inventory.flush()
	var saved := await api.get_character()
	check(saved.ok and int(saved.data["gold"]) == int(g.progress.prog.character["gold"]), "backend gold == client gold (%s vs %s)" % [saved.data.get("gold"), g.progress.prog.character["gold"]])
	check(saved.ok and (int(saved.data["experience"]) > xp0 or int(saved.data["level"]) > lvl0), "backend XP saved")
	var inv1 := await api.get_inventory(cid)
	var bag_local: int = g.ui_host.inventory.slots.size()
	check(inv1.ok and (inv1.data as Array).size() >= bag0 and (inv1.data as Array).size() == bag_local, "bag saved (%d rows local, %d server)" % [bag_local, (inv1.data as Array).size() if inv1.ok else -1])

	# ---- a spend the server prices (spend_on_server): reforge one rolled piece -------------------------------------------------------------
	var piece := {}
	for s in g.ui_host.inventory.slots:
		if int(s.get("instance_id", 0)) != 0 and int(s.get("equipped", 0)) == 0 and not (s.get("affixes", []) as Array).is_empty():
			piece = s
			break
	if piece.is_empty():
		skip("spend_on_server: no rolled, unworn piece with affixes in the bag")
	else:
		g.progress.prog.add_gold(600.0)   # stands in for more ground gold (the pickup path is asserted above); the save's lump allowance covers it
		var gold_before := int(g.progress.prog.character["gold"])
		var probe := await g.progress.psync.spend_on_server(func() -> DmResult: return await api.reforge_affix(cid, int(piece["slot_index"]), 0, 1))   # a stale price: refused, nothing taken
		check(not probe.ok and int(g.progress.prog.character["gold"]) == gold_before, "a stale-price spend is refused and costs nothing: " + probe.error)
		var cost := _price_from(probe.error)
		if cost <= 0:
			notes.append("reforge price not in the refusal text: " + probe.error)
			skip("spend_on_server: could not learn the reforge price")
		elif cost > gold_before:
			skip("spend_on_server: reforge costs %d, hero has %d" % [cost, gold_before])
		else:
			var sp := await g.progress.psync.spend_on_server(func() -> DmResult: return await api.reforge_affix(cid, int(piece["slot_index"]), 0, cost))
			check(sp.ok, "spend_on_server reforge: " + sp.error)
			check(int(g.progress.prog.character["gold"]) == gold_before - cost, "client gold follows the server's price (%d - %d)" % [gold_before, cost])
			var after := await api.get_character()
			check(after.ok and int(after.data["gold"]) == gold_before - cost, "server took exactly the price")

	# ---- session end, relog -----------------------------------------------------------------------------------------------------------------
	var end_gold := int(g.progress.prog.character["gold"])
	var end_xp := int(g.progress.prog.character["experience"])
	var end_level := int(g.progress.prog.character["level"])
	var end_kills := int(g.progress.prog.local["totalKills"])
	check(await close(), "session ended on leave")
	g = null
	if not await login():
		return
	var cr2 := await api.get_character()
	check(cr2.ok and int(cr2.data["id"]) == cid, "relog: same character")
	check(cr2.ok and int(cr2.data["gold"]) == end_gold and int(cr2.data["experience"]) == end_xp and int(cr2.data["level"]) == end_level, "relog: level / xp / gold persisted (%s/%s/%s)" % [cr2.data.get("level"), cr2.data.get("experience"), cr2.data.get("gold")])
	var n2 := await api.necro_get(cid)
	check(n2.ok and int(n2.data["progress"].get("totalKills", 0)) >= end_kills - 2, "relog: kill counts persisted (%s vs %d)" % [n2.data["progress"].get("totalKills") if n2.ok else "?", end_kills])
	var inv2 := await api.get_inventory(cid)
	check(inv2.ok and (inv2.data as Array).size() == bag_local, "relog: bag persisted")
	await launch(cr2.data)
	check(int(g.progress.prog.character["gold"]) == end_gold and int(g.progress.prog.local["totalKills"]) == int(n2.data["progress"].get("totalKills", -1)), "relaunched game restores gold and kills from the backend")
	await close()


## "The Workbench price changed ... (N gold)" style refusals: the first number in the error, 0 when none.
func _price_from(text: String) -> int:
	var rx := RegEx.new()
	rx.compile("(\\d[\\d,]*)")
	var mt := rx.search(text)
	return int(mt.get_string().replace(",", "")) if mt != null else 0
