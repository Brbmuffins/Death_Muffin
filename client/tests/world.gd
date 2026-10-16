extends SceneTree
## The whole world (ROADMAP "The other 12 areas as scenes ... moving between areas"): the game scene as a player gets it, every area but the Depths loaded,
## offline on the local mock, headless. Checks:
##   - every area scene is in, each door once; the hero starts on the Chapterhouse's return point (3 m off it, as today's host) and the people stand in the hubs;
##   - the seals at the start of a new character: the hubs and the Graves open, their doors' gates up; every sealed area and the doors to it closed (gate down,
##     collider on, its navmesh and links off); the minimap says the same;
##   - the core's copy of the navmesh (DmCore.nav_add_region) answers exactly what the navigation server answers with every region on, and keeps bodies out of
##     sealed areas and corridors;
##   - breaking a seal: the Graves' kills reach the Warren's count, the seal breaks (the banner), its gate opens and its navmesh joins; the party is told;
##   - moving between areas: the hero walks from the Chapterhouse through the Graves into the Warren; the area changes follow (banners, lighting, the director),
##     and the Warren's waves are its roster;
##   - waystone travel and the recall home (T), with the thralls following; a fallen hero gets up in the Chapterhouse;
##   - ZERO script errors or engine errors in the log.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/world.gd

class ErrorLog:
	extends Logger
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


const OUT := "user://world_test"
const BAKE := ["grave_robber", "bone_hound"]

var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var hero: DmHeroBody
var events: Array = []          ## [id, ctx] of the HUD's game events


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL world: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_ticks: int) -> bool:
	var end := Engine.get_physics_frames() + limit_ticks
	while not bool(cond.call()) and Engine.get_physics_frames() < end:
		await physics_frame
	return bool(cond.call())


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
	DmSimData.ensure()
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("world%d" % (Time.get_ticks_usec() % 100000), "w@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, 12)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "persist": false, "baked_dir": OUT})
	hero = g.local_body()
	print("INFO world: the areas load in %d ms (navigation ready %d ms later); the game in %d ms; the core holds %d navmesh triangles" % [g.world.build_ms, g.world.sync_ms, g.load_ms, g.core_host.core.nav_triangle_count()])
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append([id, ctx]))
	_the_world()
	_the_seals()
	_the_navmesh()
	await _breaking_a_seal()
	await _walking_through()
	await _waystones_and_recall()
	await _getting_up()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%s world %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


func _door(id: String) -> Dictionary:
	for d: Dictionary in DmContent.doors():
		if String(d["id"]) == id:
			return d
	return {}


func _door_mid(id: String) -> Vector3:
	var r: Dictionary = _door(id)["rect"]
	return Vector3((float(r["x0"]) + float(r["x1"])) * 0.5, 0.0, (float(r["z0"]) + float(r["z1"])) * 0.5)


func _area_mid(id: String) -> Vector3:
	var r: Dictionary = DmContent.area(id)["rect"]
	return Vector3((float(r["x0"]) + float(r["x1"])) * 0.5, 0.0, (float(r["z0"]) + float(r["z1"])) * 0.5)


func _gate_closed(id: String) -> bool:
	var gt: Dictionary = g.world.gates[id]
	return not bool(gt.open) and (gt.bars as Node3D).visible and not (gt.collider as CollisionShape3D).disabled and not (g.world.nav_regions["door:" + id] as NavigationRegion3D).enabled


func _gate_open(id: String) -> bool:
	var gt: Dictionary = g.world.gates[id]
	return bool(gt.open) and not (gt.bars as Node3D).visible and (g.world.nav_regions["door:" + id] as NavigationRegion3D).enabled


# ------------------------------------------------------------------------------------------------------------------ the world

func _the_world() -> void:
	var want := DmNextWorld.every_area()
	check(want.size() == 12 and not want.has("depths") and g.world.loaded == want, "every area but the Depths is loaded (%s)" % str(g.world.loaded))
	var doors := 0
	for id: String in g.world.loaded:
		doors += g.world.get_node("area_" + id).get_node("Doors").get_child_count()
	check(doors == DmContent.doors().size() and g.world.nav_regions.size() == 12 + doors, "each of the %d doors is in the world once (%d)" % [DmContent.doors().size(), doors])
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	check(hero.position.distance_to(Vector3(float(ret["x"]) + 3.0, 0.0, float(ret["z"]))) < 0.05 and g.area_id == "chapterhouse",
		"the hero starts 3 m from the Chapterhouse's return point, as today's host (%s, %s)" % [str(hero.position), g.area_id])
	check(g.chapterhouse != null and g.chapterhouse.npcs != null and g.chapterhouse.npcs.npcs.size() == 3, "the Chapterhouse node is up with its three people")
	var prior: Dictionary = DmContent.get_export("npcs", "NPCS")["prior"]
	var node: Node3D = g.chapterhouse.npcs.npcs["prior"]["root"]
	check(node.position.distance_to(Vector3(float(prior["x"]), 0.0, float(prior["z"]))) < 0.01, "the Prior stands where npcs.json puts him")


# ------------------------------------------------------------------------------------------------------------------ the seals

func _the_seals() -> void:
	var open_areas := ["chapterhouse", "acre", "alchemist_wing", "graves"]
	check(g.world.unlocked.keys().all(func(a: String) -> bool: return open_areas.has(a)) and g.world.unlocked.size() == 4, "a new character's open areas are the hubs and the Graves (%s)" % str(g.world.unlocked.keys()))
	var wrong: Array = []
	for id: String in g.world.loaded:
		if (g.world.nav_regions["area:" + id] as NavigationRegion3D).enabled != open_areas.has(id):
			wrong.append(id)
	check(wrong.is_empty(), "a sealed area's navmesh is off, an open one's on (wrong: %s)" % str(wrong))
	var closed_ok := true
	var open_ok := true
	for d: Dictionary in DmContent.doors():
		var id := String(d["id"])
		if id == "chapter_graves":
			continue
		var both := open_areas.has(String(d["a"])) and open_areas.has(String(d["b"]))
		if both:
			open_ok = open_ok and _gate_open(id)
		else:
			closed_ok = closed_ok and _gate_closed(id)
	check(open_ok, "the hubs' doors stand open (gates up, navmesh on)")
	check(closed_ok, "every door into a sealed area is closed (gate down, collider on, navmesh and links off)")
	check(not g.world.gates.has("chapter_graves") and (g.world.nav_regions["door:chapter_graves"] as NavigationRegion3D).enabled, "the Graves' door to the Chapterhouse has no gate and is always open")
	var vm: Dictionary = g.ui_host.hud_state()
	var map_doors: Dictionary = {}
	for d: Dictionary in vm["minimap"]["doors"]:
		map_doors[String(d["id"])] = bool(d["open"])
	check(map_doors.get("graves_warren", true) == false and map_doors.get("chapter_acre", false) == true, "the minimap shows the sealed door closed and the hub door open")


# ------------------------------------------------------------------------------------------------------------------ the navmesh

func _the_navmesh() -> void:
	var core: RefCounted = g.core_host.core
	check(core.nav_triangle_count() > 1000, "the core holds the navmesh's triangles (%d)" % core.nav_triangle_count())
	var warren := _area_mid("warren")
	var c: Vector3 = core.nav_closest(warren)
	check(g.world.area_at(c.x, c.z) != "warren", "the core keeps a body out of the sealed Warren (%s -> %s)" % [str(warren), str(c)])
	var corridor := _door_mid("graves_warren")
	c = core.nav_closest(corridor)
	check(c.distance_to(corridor) > 0.5, "...and out of its sealed corridor")
	# every region on: the core answers what the navigation server answers
	g.world.set_unlocked(DmNextWorld.every_area())
	var map := g.world.nav_map()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var b := g.world.bounds(2.0)
	var worst := 0.0
	for i in 1500:
		var p := Vector3(rng.randf_range(b.position.x, b.end.x), 0.0, rng.randf_range(b.position.y, b.end.y))
		var a := NavigationServer3D.map_get_closest_point(map, p)
		var q: Vector3 = core.nav_closest(p)
		worst = maxf(worst, Vector2(a.x - q.x, a.z - q.z).length())
	check(worst < 0.001, "with every region on, the core's closest point is the navigation server's at 1500 points (worst %.5f m)" % worst)
	g.chapterhouse.apply_seals()   # back to the character's seals
	check(g.world.unlocked.size() == 4 and _gate_closed("graves_warren"), "the seals are back")


# ------------------------------------------------------------------------------------------------------------------ breaking a seal

func _breaking_a_seal() -> void:
	var prog := g.ui_host.prog
	var u: Dictionary = DmContent.area("warren")["unlock"]
	prog.local["areaKills"][String(u["area"])] = prog.unlock_kills(float(u["kills"]))
	events.clear()
	var broken: Array = g.chapterhouse.check_seals()
	check(broken == ["warren"], "the Graves' %d kills break the Warren's seal (%s)" % [prog.unlock_kills(float(u["kills"])), str(broken)])
	var banner := events.filter(func(e: Array) -> bool: return e[0] == "banner" and String(e[1].get("title", "")) == "A seal breaks")
	check(banner.size() == 1 and String(banner[0][1]["sub"]).contains("Warren"), "the banner says so (%s)" % str(banner))
	check(_gate_open("graves_warren") and (g.world.nav_regions["area:warren"] as NavigationRegion3D).enabled, "the Warren's gate is up and its navmesh joins")
	check(g.party._seals.has("warren"), "the party is told (a guest's doors follow the host's seals)")
	var goal := g.world.nav_closest(_area_mid("warren"))
	var from := g.world.nav_closest(_area_mid("graves"))
	var hold := [PackedVector3Array()]
	await until(func() -> bool:   # the navigation server merges the opened regions on its own thread, a few frames later
		hold[0] = g.world.nav_path(from, goal)
		return hold[0].size() > 1 and g.world.area_at(hold[0][-1].x, hold[0][-1].z) == "warren", 120)
	var path: PackedVector3Array = hold[0]
	check(path.size() > 1 and Vector2(path[-1].x - goal.x, path[-1].z - goal.z).length() < 0.5 and g.world.area_at(path[-1].x, path[-1].z) == "warren",
		"a path runs from the Graves into the Warren (%d points, ends %s)" % [path.size(), str(path[-1]) if path.size() > 0 else "-"])


# ------------------------------------------------------------------------------------------------------------------ moving between areas

func _walking_through() -> void:
	var seen: Array = []
	g.area_changed.connect(func(id: String) -> void: seen.append(id))
	for goal: Vector3 in [_area_mid("graves"), _area_mid("warren")]:
		g.session.request_move_to(goal)
		var ok := await until(func() -> bool: return Vector2(hero.position.x - goal.x, hero.position.z - goal.z).length() < 1.5, 60 * 40)
		check(ok, "the hero walks to %s (at %s)" % [str(goal), str(hero.position)])
	check(seen == ["graves", "warren"], "the area follows him: the Graves, then the Warren (%s)" % str(seen))
	check(g.area_id == "warren" and g.world.area_id == "warren", "the game's area and the lighting's are the Warren")
	var entry := events.filter(func(e: Array) -> bool: return e[0] == "banner" and String(e[1].get("title", "")).contains("Warren"))
	check(not entry.is_empty(), "the Warren's entry banner shows")
	var spawned: Array = []
	g.core_host.enemy_spawned.connect(func(_id: int, d: String, _l: int, _e: bool, a: String, _af: int, _x: float, _z: float, _h: float) -> void: spawned.append([d, a]))
	g.director.enabled = true
	await until(func() -> bool: return spawned.size() >= 4, 60 * 20)
	g.director.enabled = false
	var roster := {}
	for e in DmContent.area("warren").get("enemies", []):
		roster[String(e["id"])] = true
	check(not spawned.is_empty() and spawned.all(func(s: Array) -> bool: return String(s[1]) == "warren" and roster.has(String(s[0]))),
		"the director follows him: the Warren's waves are its roster (%s)" % str(spawned.slice(0, 6)))
	for id in g.core_host.core.enemy_ids():
		g.core_host.remove_enemy(id)


# ------------------------------------------------------------------------------------------------------------------ waystones and the recall

func _waystones_and_recall() -> void:
	var c := hero.get_node("Rites") as DmRiteCaster
	var cp := g.core_host.corpses.add_corpse(hero.position.x + 2.0, hero.position.z, "normal", "robber", false, 0.0, 1.0, g.area_id)
	var ex := {"kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": c.mods["thrallAttackSpeedMult"], "r": 0.8}
	var raised: Dictionary = c.thralls().raise(ex, hero.position + Vector3(2.0, 0, 0))
	check(bool(raised["ok"]) and cp > 0, "a thrall walks with him")
	g.chapterhouse.start_recall()   # 1.5 s of wall time standing still, as today's
	await until(func() -> bool: return not g.chapterhouse.recall_active, 60 * 120)
	await ticks(3)
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	check(Vector2(hero.position.x - float(ret["x"]), hero.position.z - float(ret["z"])).length() < 0.05 and g.area_id == "chapterhouse", "T: after the recall he stands in the Chapterhouse (%s)" % str(hero.position))
	var tid := int((raised["thralls"] as Array)[0]) if bool(raised["ok"]) else 0
	check(tid != 0 and c.thralls().near(hero.position, 3.0).has(tid), "his thrall came home with him")
	var stone: Dictionary = {}
	for w: Dictionary in g.chapterhouse.waystones:
		if String(w["area"]) == "graves":
			stone = w
	g.chapterhouse.travel("graves")
	await ticks(3)
	check(not stone.is_empty() and Vector2(hero.position.x - float(stone["x"]), hero.position.z - (float(stone["z"]) + 1.6)).length() < 0.05 and g.area_id == "graves",
		"the waystone takes him from the Chapterhouse to the Graves' stone (%s)" % str(hero.position))
	g.chapterhouse.travel("ossuary")
	await ticks(2)
	check(g.area_id == "graves", "a sealed area's stone refuses him")


# ------------------------------------------------------------------------------------------------------------------ getting up

func _getting_up() -> void:
	hero.take_damage(1.0e7, 0, "melee")
	check(not hero.alive, "the hero falls in the Graves")
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	var up := await until(func() -> bool: return hero.alive, 60 * 8)
	await ticks(2)
	check(up and Vector2(hero.position.x - float(ret["x"]), hero.position.z - float(ret["z"])).length() < 0.05, "he gets up in the Chapterhouse, as today (%s)" % str(hero.position))
