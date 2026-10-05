extends RefCounted
## Scripted gather sessions against DmGatherLoop / DmSkills / DmNodeViews with a stub host (real DmPlayer + DmNav, fake `post`).

var passed := 0
var failed := 0

# stub host state
var now := 1000.0
var live: Dictionary = {}
var nodes: Array = []
var bag_ok := true
var auto := false
var rand_v := 0.0
var successes: Array = []
var cycles: Array = []
var stops: Array = []
var replies: Array = []
var errors: Array = []
var posts: Array = []
var post_result: Callable
var skills: DmSkills
var player: DmPlayer
var loop: DmGatherLoop
var nav: DmNav


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", what)


func _world_nodes() -> Array:
	var f := FileAccess.open("res://data/slice/world.json", FileAccess.READ)
	return JSON.parse_string(f.get_as_text())["nodes"]


func _find(type: String, area: String, k: int = 0) -> Dictionary:
	var i := 0
	for n in _world_nodes():
		if n["type"] == type and n["area"] == area:
			if i == k:
				var d: Dictionary = n.duplicate()
				d["remaining"] = 5
				return d
			i += 1
	return {}


func _reply(type: String, actions: int) -> Dictionary:
	var def := DmGathering.node_def(type)
	return {"node": type, "skill": def["skill"], "accepted": actions, "successes": actions, "xp": actions * int(def["xp"]), "gold": 0,
		"items": [{"itemId": def["item"], "qty": actions}], "rejected": [], "leveledUp": false, "toolTier": 0,
		"skills": [{"profession_id": def["skill"], "skill_level": 2, "skill_xp": 3}]}


func _reset(start_x: float, start_z: float, level_rows: Array = []) -> void:
	now = 1000.0
	live = {}
	nodes = []
	bag_ok = true
	auto = false
	rand_v = 0.0
	successes = []
	cycles = []
	stops = []
	replies = []
	errors = []
	posts = []
	post_result = func(type: String, actions: int, _ka: bool, _afk: bool) -> DmResult:
		return DmResult.success(_reply(type, actions))
	skills = DmSkills.new(level_rows)
	player = DmPlayer.new({"x": start_x, "z": start_z, "facing": 0.0, "alive": true}, nav)
	var hooks := {
		"now": func(): return now,
		"rand": func(): return rand_v,
		"nav": nav,
		"player": player,
		"nodes": func(): return nodes,
		"live": func(id): return live.get(id, true),
		"bagFits": func(_i): return bag_ok,
		"sendSuccess": func(id): successes.append(id),
		"post": func(type, actions, ka, afk_):
			posts.append([type, actions, ka, afk_])
			return await post_result.call(type, actions, ka, afk_),
		"onCycle": func(def, ok, n): cycles.append([def["id"], ok, n["id"]]),
		"onReply": func(r): replies.append(r),
		"onStop": func(reason, msg): stops.append([reason, msg]),
		"onError": func(m): errors.append(m),
		"autoEnabled": func(): return auto,
	}
	loop = DmGatherLoop.new(hooks, skills)


## Finish a walk instantly (what DmPlayer.update would do over time).
func _arrive() -> void:
	var d: Variant = player.destination()
	if d != null:
		player.p["x"] = d["x"]
		player.p["z"] = d["z"]
	player.stop()


func run(tree: SceneTree) -> void:
	nav = DmNav.new()
	await _skills_tests()
	await _start_tests()
	await _work_tests()
	await _stop_tests()
	await _auto_tests()
	await _flush_tests()
	await _api_tests()
	await _views_tests(tree)


func _skills_tests() -> void:
	var s := DmSkills.new([{"profession_id": "mining", "skill_level": 5, "skill_xp": 120}, {"profession_id": "bogus", "skill_level": 9, "skill_xp": 1}])
	check(s.level("mining") == 5 and s.level("woodcutting") == 1 and s.level("bogus") == 1, "skills adopt: server rows win, unknown ignored, default 1")
	check(s.shown("mining") == {"level": 5, "xp": 120, "next": 250}, "shown without pending")
	s.add_pending("mining", 140)
	var sh := s.shown("mining")
	check(sh["level"] == 6 and sh["xp"] == 10 and sh["next"] == 300, "pending XP levels up the shown value: %s" % str(sh))
	check(s.level("mining") == 5, "real level unchanged by pending")
	s.adopt([{"profession_id": "mining", "skill_level": 6, "skill_xp": 10}], "mining")
	check(s.shown("mining") == {"level": 6, "xp": 10, "next": 300}, "adopt with clear_pending_for drops optimistic XP")
	s.adopt([{"profession_id": "mining", "skill_level": 0, "skill_xp": -4}])
	check(s.get_skill("mining") == {"level": 1, "xp": 0}, "adopt clamps level>=1 xp>=0")
	check(s.gate_level("mining") == 1, "gate level = real level")
	s.dev_access = true
	check(s.gate_level("mining") == 99 and s.level("mining") == 1, "dev access gate = cap, level untouched")
	var fired := [0]
	s.changed.connect(func(): fired[0] += 1)
	s.add_pending("fishing", 1)
	check(fired[0] == 1, "changed signal on add_pending")
	check(s.rows().size() == 7 and s.total() == 7, "rows/total over all 7 skills")


func _start_tests() -> void:
	var oak := _find("coffin_oak", "acre")
	_reset(float(oak["x"]), float(oak["z"]) + 8.0)
	check(loop.start({"type": "nope", "id": "x", "x": 0, "z": 0}) == "Nothing to gather here.", "unknown node refusal")
	var iron := _find("seam_iron", "acre")
	check(loop.start(iron) == "Requires Mining level 10", "level gate text: " + loop.start(iron))
	bag_ok = false
	check(loop.start(oak) == "Your bag is full.", "bag full refusal")
	bag_ok = true
	check(not loop.active and loop.status == "Paused", "idle status Paused")
	check(loop.start(oak) == "" and loop.active, "start ok")
	check(loop.status == "Walking to: Coffin-Oak" and player.has_path() and not loop.working, "walking status + path set")
	loop.update(0.016)
	check(loop.status == "Walking to: Coffin-Oak", "still walking while the path is set")
	_arrive()
	loop.update(0.016)
	check(loop.working and loop.status == "Working: Coffin-Oak", "arrival begins work")
	var want := atan2(float(oak["x"]) - player.x, float(oak["z"]) - player.z)
	check(absf(player.facing - want) < 1e-6, "hero faces the node")
	# already standing on the ring: starts working immediately
	var spot := DmGathering.stand_spot(nav.blocked, oak, player.x, player.z)
	loop.stop("panel")
	_reset(spot["x"], spot["z"])
	check(loop.start(oak) == "" and loop.working, "start on the ring begins work with no walk")
	# depleted node: start waits
	_reset(float(oak["x"]), float(oak["z"]) + 8.0)
	live[oak["id"]] = false
	check(loop.start(oak) == "" and loop.status == "Waiting for respawn: Coffin-Oak" and player.has_path(), "start on a spent node waits (and walks to the ring)")
	# dev access lets a low-level hero start
	_reset(float(iron["x"]), float(iron["z"]) + 8.0)
	skills.dev_access = true
	check(loop.start(iron) == "", "dev access passes the level gate")


func _work_tests() -> void:
	var oak := _find("coffin_oak", "acre")
	var spot := DmGathering.stand_spot(nav.blocked, oak, float(oak["x"]), float(oak["z"]) + 5.0)
	_reset(spot["x"], spot["z"])
	now = 0.0    # GatherLoop.lastFlush starts at 0 (as in the TS), so the first flush needs now >= 8000
	loop.start(oak)
	var ms := float(DmGathering.action_ms(DmGathering.node_def("coffin_oak")))
	check(ms == 2400.0, "coffin_oak cycle = 4 ticks x 600 ms")
	loop.update(2.3)
	check(cycles.is_empty() and absf(loop.progress - 2300.0 / ms) < 1e-9, "no cycle before action_ms; progress arc fraction")
	loop.update(0.1)
	check(cycles.size() == 1 and cycles[0] == ["coffin_oak", true, oak["id"]] and successes == [oak["id"]], "cycle lands at action_ms (success with rand 0)")
	check(loop.progress < 1e-6, "progress wraps after a cycle")
	check(int(skills.shown("woodcutting")["xp"]) == 6, "success adds optimistic XP (def.xp)")
	rand_v = 0.99
	loop.update(2.4)
	check(cycles.size() == 2 and cycles[1][1] == false and successes.size() == 1, "failed roll: onCycle(false), no depletion, no XP")
	check(int(skills.shown("woodcutting")["xp"]) == 6, "failed roll adds no XP")
	# a long frame carries the remainder
	rand_v = 0.0
	loop.update(2.4 + 1.2)
	check(cycles.size() == 3 and absf(loop.progress - 0.5) < 1e-9, "remainder carries into the next cycle")
	# queue flushes after GATHER_FLUSH_MS, not before
	check(posts.is_empty(), "no post yet")
	now += float(DmGathering.GATHER_FLUSH_MS) - 1.0
	loop.update(0.0)
	check(posts.is_empty(), "no post before flush interval")
	now += 1.0
	loop.update(0.0)
	check(posts == [["coffin_oak", 3, false, false]], "flush after 8s posts the batched cycles: %s" % str(posts))
	check(replies.size() == 1 and skills.level("woodcutting") == 2 and int(skills.get_skill("woodcutting")["xp"]) == 3, "reply adopted (level-up via Skills.adopt)")
	check(int(skills.shown("woodcutting")["xp"]) == 3, "pending XP cleared by the reply")
	# a leveled hero uses the higher level for the roll
	check(absf(DmGathering.success_chance(DmGathering.node_def("coffin_oak"), 2) - 0.61) < 1e-9, "success chance uses skill level")


func _stop_tests() -> void:
	var oak := _find("coffin_oak", "acre")
	var spot := DmGathering.stand_spot(nav.blocked, oak, float(oak["x"]), float(oak["z"]) + 5.0)
	# bag full while working
	_reset(spot["x"], spot["z"])
	loop.start(oak)
	loop.update(2.4)
	bag_ok = false
	loop.update(0.016)
	check(stops == [["bagFull", ""]] and not loop.active, "bag full stops the loop")
	check(loop.status == "Bag full — make room, then Start AFK again.", "bag full status text")
	check(DmGathering.STOP_TEXT["bagFull"] == "Your bag is full. Visit the Reliquary or drop something to keep gathering.", "STOP_TEXT bagFull")
	check(posts.size() == 1 and posts[0] == ["coffin_oak", 1, false, false], "stop flushes the queued cycle")
	# bag full on a walk
	_reset(float(oak["x"]), float(oak["z"]) + 8.0)
	loop.start(oak)
	bag_ok = false
	loop.update(0.016)
	check(stops == [["bagFull", ""]], "bag full stops during the walk")
	# moved: hero got a path (WASD / click) while working
	_reset(spot["x"], spot["z"])
	loop.start(oak)
	player.move_along([[spot["x"] + 1.0, spot["z"]]])
	loop.update(0.016)
	check(stops == [["moved", ""]] and loop.status == "Paused", "a new path while working stops with 'moved'")
	# moved: pushed too far
	_reset(spot["x"], spot["z"])
	loop.start(oak)
	player.p["x"] = float(oak["x"]) + 10.0
	loop.update(0.016)
	check(stops == [["moved", ""]], "drifting past reach+slack stops with 'moved'")
	# unreachable: walk ends too far from the ring
	_reset(float(oak["x"]), float(oak["z"]) + 8.0)
	loop.start(oak)
	player.stop()
	loop.update(0.016)
	check(stops == [["unreachable", "You cannot reach that."]] and loop.status == "You cannot reach that.", "walk ending short = unreachable")
	# spent, no auto
	_reset(spot["x"], spot["z"])
	loop.start(oak)
	live[oak["id"]] = false
	loop.update(0.016)
	check(stops == [["blocked", "The Coffin-Oak is spent."]] and loop.status == "The Coffin-Oak is spent.", "spent node stops (no auto): " + str(stops))
	# stop with no node is a no-op; external stop reasons
	loop.stop("hurt")
	check(stops.size() == 1, "stop while idle does nothing")
	_reset(spot["x"], spot["z"])
	loop.start(oak)
	loop.stop("hurt", DmGathering.STOP_TEXT["hurt"])
	check(loop.status == "Something struck you. Gathering stopped." and stops[0][0] == "hurt", "hurt stop carries STOP_TEXT message")
	_reset(spot["x"], spot["z"])
	loop.start(oak)
	loop.stop("panel")
	check(loop.status == "Paused", "stop without text reads Paused")


func _auto_tests() -> void:
	var a := _find("coffin_oak", "acre", 0)
	var b := _find("coffin_oak", "acre", 1)
	var spot := DmGathering.stand_spot(nav.blocked, a, float(a["x"]), float(a["z"]) + 5.0)
	_reset(spot["x"], spot["z"])
	nodes = [a, b]
	auto = true
	loop.start(a)
	live[a["id"]] = false
	loop.update(0.016)
	check(loop.node["id"] == b["id"] and stops.is_empty(), "Auto jumps to the nearest live node of the same kind")
	check(loop.status == "Walking to: Coffin-Oak" or loop.working, "and walks/works there")
	# nothing else live: wait here, resume when it respawns
	_reset(spot["x"], spot["z"])
	nodes = [a]
	auto = true
	loop.start(a)
	live[a["id"]] = false
	loop.update(0.016)
	check(loop.status == "Waiting for respawn: Coffin-Oak" and stops.is_empty(), "Auto with nothing live waits for respawn")
	live[a["id"]] = true
	loop.update(0.016)
	check(loop.working, "respawn resumes work")
	# AFK path
	_reset(spot["x"], spot["z"])
	nodes = [a]
	check(loop.start_afk(a) == "" and loop.afk, "start_afk sets afk")
	loop.update(2.4)
	loop.stop("bagFull")
	check(posts == [["coffin_oak", 1, false, true]] and not loop.afk, "stop flushes with afk=true then clears afk")
	_reset(spot["x"], spot["z"])
	var iron := _find("seam_iron", "acre")
	check(loop.start_afk(iron) != "" and not loop.afk, "start_afk refusal leaves afk off")
	# AFK + depleted + start refuses (bag) -> blocked
	_reset(spot["x"], spot["z"])
	nodes = [a, b]
	loop.start_afk(a)
	live[a["id"]] = false
	bag_ok = true
	loop.update(0.016)
	check(loop.node["id"] == b["id"], "AFK also auto-advances without the Auto toggle")


func _flush_tests() -> void:
	var oak := _find("coffin_oak", "acre")
	var spot := DmGathering.stand_spot(nav.blocked, oak, float(oak["x"]), float(oak["z"]) + 5.0)
	# batch cap: GATHER_MAX_BATCH cycles flush immediately and split in chunks of 40
	_reset(spot["x"], spot["z"])
	loop.start(oak)
	for i in 45:
		loop.update(2.4)
		now += 1.0
	# 40th cycle triggers the flush at the next update; remaining cycles queued after
	await loop.flush()
	var total := 0
	for p in posts:
		total += int(p[1])
		check(int(p[1]) <= 40, "no post over the batch cap")
	check(total == 45, "all 45 cycles posted (%d)" % total)
	# server hiccup: keep cycles, retry 10s later
	_reset(spot["x"], spot["z"])
	post_result = func(_t2, _a, _k, _f) -> DmResult: return DmResult.failure("Cannot reach server", 0)
	loop.start(oak)
	loop.update(2.4)
	loop.update(2.4)
	await loop.flush()
	check(posts.size() == 1 and replies.is_empty() and errors.is_empty(), "offline: one attempt, no reply, no error shown")
	now += 5000.0
	loop.update(0.0)
	check(posts.size() == 1, "no retry before 10s")
	post_result = func(type, actions, _k, _f) -> DmResult: return DmResult.success(_reply(type, actions))
	now += 5001.0
	loop.update(0.0)
	check(posts.size() == 2 and posts[1][1] == 2 and replies.size() == 1, "retry after 10s sends the kept cycles: %s" % str(posts))
	# refusal: final, message surfaced, optimistic XP dropped
	_reset(spot["x"], spot["z"])
	post_result = func(_t2, _a, _k, _f) -> DmResult: return DmResult.failure("You are gathering faster than your hands allow. Slow down.", 429)
	loop.start(oak)
	loop.update(2.4)
	check(int(skills.shown("woodcutting")["xp"]) == 6, "optimistic XP shown")
	await loop.flush()
	check(errors == ["You are gathering faster than your hands allow. Slow down."], "refusal text passed to onError verbatim")
	check(int(skills.shown("woodcutting")["xp"]) == 0, "refusal clears the optimistic XP for that skill")
	await loop.flush()
	check(posts.size() == 1, "refused cycles are not retried")
	# server error 500 retried too
	_reset(spot["x"], spot["z"])
	post_result = func(_t2, _a, _k, _f) -> DmResult: return DmResult.failure("boom", 500)
	loop.start(oak)
	loop.update(2.4)
	await loop.flush()
	check(errors.is_empty() and loop.hooks != null, "500 treated as a hiccup")
	# concurrent flush() while one is out waits for it
	_reset(spot["x"], spot["z"])
	loop.start(oak)
	loop.update(2.4)
	await loop.flush()
	await loop.flush()
	check(posts.size() == 1, "empty flush posts nothing")


func _api_tests() -> void:
	# the real DmApi on the offline backend: gather is served there (the server's time budget and rules)
	var mock := DmMockBackend.new("")
	mock.now_ms = func(): return 1700000000000
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	var r: DmResult = await api.register("tester", "t@example.com", "secretpw")
	api.set_token(str(r.data["token"]))
	var ch: DmResult = await api.load_or_create_character(0)
	var oak := _find("coffin_oak", "acre")
	var spot := DmGathering.stand_spot(nav.blocked, oak, float(oak["x"]), float(oak["z"]) + 5.0)
	_reset(spot["x"], spot["z"])
	var post := DmGatherLoop.api_post(api, int(ch.data["id"]))
	var res: DmResult = await post.call("coffin_oak", 3, false, true)
	check(not res.ok and res.status == 400 and res.error == "Start AFK gathering from Skills first.", "api_post reaches DmApi.gather (the backend refuses AFK before afk-start)")
	var res2: DmResult = await post.call("coffin_oak", 3, false, false)
	check(res2.ok and res2.data["node"] == "coffin_oak" and int(res2.data["accepted"]) == 3, "api_post gathers on the offline backend")
	loop.hooks["post"] = post
	loop.start(oak)
	loop.update(2.4)
	await loop.flush()
	check(errors.is_empty(), "a flush against the offline backend is not an error")


func _fake_builder(defs: Array) -> Object:
	var b := RefCounted.new()
	b.set_script(preload("res://tests/game/fake_builder.gd"))
	var root := Node3D.new()
	b.area_nodes = {"acre": root}
	b.world = {"nodes": defs}
	for n in defs:
		var parent := Node3D.new()
		parent.position = Vector3(n["x"], 0.04, n["z"])
		root.add_child(parent)
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		parent.add_child(mi)
		b.node_views[n["id"]] = parent
	return b


func _views_tests(tree: SceneTree) -> void:
	var tree_n := _find("coffin_oak", "acre")
	var herb := {"id": "h1", "type": "rot_cap_patch", "kind": "herb", "x": 3.0, "z": 4.0, "area": "acre", "rich": true, "spentModel": null}
	var pool := {"id": "p1", "type": "pool_still", "kind": "pool", "x": 6.0, "z": 7.0, "area": "acre"}
	var defs: Array = [tree_n, herb, pool]
	tree_n["spentModel"] = null
	tree_n["kind"] = "tree"
	var b := _fake_builder(defs)
	var views := DmNodeViews.new()
	views.setup(b)
	tree.root.add_child(views)
	check(b.node_views["h1"].scale.x > 1.1, "rich node scaled 1.12")
	# live / spent
	var kids: Array = b.node_views[tree_n["id"]].get_children()
	views.set_live(tree_n["id"], false)
	check(not kids[0].visible, "set_live(false) hides the live look")
	views.set_live(tree_n["id"], true)
	check(kids[0].visible, "set_live(true) shows it again")
	views.set_live("h1", false)
	var herb_kids: Array = b.node_views["h1"].get_children()
	check(herb_kids.size() == 2 and herb_kids[1].visible and herb_kids[1].get_child_count() == 3, "herb spent look = 3 bare stalks")
	views.set_live("h1", true)
	check(not herb_kids[1].visible and herb_kids[0].visible, "herb back to live")
	views.set_live("missing", false)    # unknown id: no-op
	# hover
	views.hover(tree_n, true)
	var hv: MeshInstance3D = views._hover
	check(hv.visible and hv.position.is_equal_approx(Vector3(tree_n["x"], 0.04, tree_n["z"])) and is_equal_approx(hv.scale.x, 1.0), "hover ring on a tree: pos, scale 1")
	var ok_col: Color = views._hover_mat.albedo_color
	var want := Color.html("#c9a36b").lerp(DmNodeViews.BONE, 0.25)
	check(absf(ok_col.r - want.r) < 1e-4 and absf(ok_col.a - 0.6) < 1e-6, "hover colour = skill colour lerp bone 0.25")
	views.hover(tree_n, false)
	check(views._hover_mat.albedo_color.is_equal_approx(Color(Color.html("#c0504d"), 0.6)), "unusable hover is red")
	views.hover(pool, true)
	check(is_equal_approx(hv.scale.x, 1.25), "pool hover scale 1.25")
	views.hover(herb, true)
	check(is_equal_approx(hv.scale.x, 0.95), "herb hover scale 0.95")
	views.hover(null)
	check(not hv.visible, "hover(null) hides")
	# selected
	views.selected(pool)
	check(views._selected.visible and is_equal_approx(views._selected.position.y, 0.035) and is_equal_approx(views._selected.scale.x, 1.25), "selected ring")
	views.update(0.5)
	var a1: float = views._selected_mat.albedo_color.a
	check(absf(a1 - (0.42 + sin(0.9) * 0.06)) < 1e-4, "selected ring pulse")
	views.selected({})
	check(not views._selected.visible, "selected hides")
	# progress arc
	views.progress(1.0, 2.0, 0.0, "#c9a36b")
	check(not views._arc.visible, "progress 0 hides the arc")
	views.progress(1.0, 2.0, 0.5, "#c9a36b")
	check(views._arc.visible and views._arc.position.is_equal_approx(Vector3(1, 0.05, 2)) and (views._arc.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() == 24 * 6, "arc half drawn (24 of 48 segments)")
	views.progress(1.0, 2.0, 1.5, "#c9a36b")
	check((views._arc.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() == 48 * 6, "arc clamps at full ring")
	# pool pulse
	views.update(0.0)
	check(views._pools.size() == 1, "one pool group")
	views.queue_free()
