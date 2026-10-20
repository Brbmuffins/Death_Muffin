extends SceneTree
## The whole world (DECISIONS B47): the game scene as a player gets it, every area but the Depths loaded,
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
##   - the Ossuary: its seal breaks with the Graves' kills, the director makes its whole roster (the lead of its wave theme), and a deacon the director made
##     raises a corpse into a Risen at its own level and blesses a wounded ally, through the game scene's event chain (telegraph, cue, the counsel's Sanctify fact);
##   - the Drowned Nave: its seal breaks with the Ossuary's kills, the director makes its whole roster (each wave theme leads with its own kind), and in the game scene
##     the censer's incense hastes the bodies near it and its cloud is drawn, the wraith's scream and the gargoyle's dive are announced and land, the templar's shield glances, and an
##     acolyte that sees the hero's thrall killed claims the fall: Unbind's cue and thread, a Risen of the acolyte's level, its reach ring while a thrall stands in it;
##   - the Bell Sanctum, the Bone Coliseum and the Plague Cloister: their seals break (the Nave's and the Sanctum's kills; the Coliseum's broke with the Ossuary's), the director makes each
##     one's whole roster (each wave theme's lead), and in the game scene the seraph's ward blesses its neighbour (its cue, the status, the counsel
##     hears the Sanctify), the plague doctor's flask is announced and lands with its pool, and a wounded flagellant is frenzied (the status, the blood motes);
##   - the Cinder Pyre and the Mourning Fen: their seals break with the Cloister's and the Pyre's kills, the director makes their whole rosters (each wave theme leads with its own kind), and in the game scene the Husk's embers are a pool that burns him and burns out, the Priest's coal, the Slag Brute's slam, the Hag's hex, the Wisp's pulse and
##     the Sexton's chain are announced and reach him (as ember, curse, dust and melee blows, a chill, a drag and a root on his body), the Leech's bite is toxic, and the kinds shed
##     embers and marsh-lights near him;
##   - waves follow the hero from area to area (the Graves, the Ossuary, the Nave, the Graves again), and the ground left behind is cleared, as today's director does;
##   - a party apart (the host in the Graves, a member in the Ossuary): each area gets its own waves around the one standing there, a party together keeps one clock and one cap, the biggest
##     fight (the global cap) is shared between the areas and never doubled, an area its last member left is cleared after EMPTY_CLEAR_S, and the director moves to the member's area when the host leaves its own;
##   - ZERO script errors or engine errors in the log.
## The navigation server merges a region that was just enabled on a worker thread of its own, and a game under --fixed-fps outruns it on a loaded machine: a path asked before the
## merge ends in the nearest ground that is merged, and a body walks away from where it was sent. The suite makes the merges synchronous (DM_SYNC_NAV, as tools/godot/run-all-tests.sh does
## for today's suites), so every path in it is the same on every run.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/world.gd

class ErrorLog:
	extends Logger
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://world_test"
const BAKE := ["grave_robber", "bone_hound"]

var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var hero: DmHeroBody
var events: Array = []          ## [id, ctx] of the HUD's game events
var _pins := {}                 ## peer id -> where `_put` holds that player's body


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
	OS.set_environment("DM_SYNC_NAV", "1")   # (DmNextWorld reads it when the game starts)
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
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
	await _the_ossuary()
	await _the_nave()
	await _the_late_areas()
	await _the_pyre_and_fen()
	await _waves_follow_the_hero()
	await _waves_in_two_areas()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%s world %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


## True when the navigation server's map has the ground between two points joined: its path ends where asked (not on the nearest ground that is merged).
func _nav_joins(from: Vector3, to: Vector3) -> bool:
	var path := g.world.nav_path(from, to)
	return path.size() > 1 and Vector2(path[path.size() - 1].x - to.x, path[path.size() - 1].z - to.z).length() < 0.5


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


## The loaded areas a new character has open: those whose world.json entry has no seal (unlock: null).
func _open_area_ids() -> Array:
	var out: Array = []
	for id: String in g.world.loaded:
		if DmData.world()["areas"][id]["unlock"] == null:
			out.append(id)
	return out


## Every area not yet open that the kills of `u["area"]` break the seal of at `u["kills"]`, sorted (what check_seals reports when that count is reached; ask before it runs).
func _opened_by(u: Dictionary) -> Array:
	var out: Array = []
	for id in DmContent.area_order():
		var un: Variant = DmContent.area(String(id)).get("unlock")
		if un != null and String(un["area"]) == String(u["area"]) and float(un["kills"]) <= float(u["kills"]) and not g.world.unlocked.has(String(id)):
			out.append(String(id))
	out.sort()
	return out


func _gate_closed(id: String) -> bool:
	var gt: Dictionary = g.world.gates[id]
	return not bool(gt.open) and (gt.bars as Node3D).visible and not (gt.collider as CollisionShape3D).disabled and not (g.world.nav_regions["door:" + id] as NavigationRegion3D).enabled


func _gate_open(id: String) -> bool:
	var gt: Dictionary = g.world.gates[id]
	return bool(gt.open) and not (gt.bars as Node3D).visible and (g.world.nav_regions["door:" + id] as NavigationRegion3D).enabled


# ------------------------------------------------------------------------------------------------------------------ the world

func _the_world() -> void:
	var want := DmNextWorld.every_area()
	var not_instances: Array = []
	for id in DmData.world()["order"]:
		if not bool(DmData.world()["areas"][id]["instance"]):
			not_instances.append(String(id))
	check(not want.is_empty() and want == not_instances and not want.has("depths") and g.world.loaded == want, "every area but the Depths (the instance) is loaded (%s)" % str(g.world.loaded))
	var doors := 0
	for id: String in g.world.loaded:
		doors += g.world.get_node("area_" + id).get_node("Doors").get_child_count()
	check(doors == DmContent.doors().size() and g.world.nav_regions.size() == g.world.loaded.size() + doors, "each of the %d doors is in the world once (%d)" % [DmContent.doors().size(), doors])
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	check(hero.position.distance_to(Vector3(float(ret["x"]) + 3.0, 0.0, float(ret["z"]))) < 0.05 and g.area_id == "chapterhouse",
		"the hero starts 3 m from the Chapterhouse's return point, as today's host (%s, %s)" % [str(hero.position), g.area_id])
	var people: Dictionary = DmContent.get_export("npcs", "NPCS")
	check(g.chapterhouse != null and g.chapterhouse.npcs != null and not people.is_empty() and g.chapterhouse.npcs.npcs.size() == people.size(), "the Chapterhouse node is up with its %d people (npcs.json)" % people.size())
	var prior: Dictionary = DmContent.get_export("npcs", "NPCS")["prior"]
	var node: Node3D = g.chapterhouse.npcs.npcs["prior"]["root"]
	check(node.position.distance_to(Vector3(float(prior["x"]), 0.0, float(prior["z"]))) < 0.01, "the Prior stands where npcs.json puts him")
	# area_at walks the loaded rects as flat numbers; it must answer what the walk over world.json's rects answers, for points in every area, on every edge and outside them all.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261017
	var walk := func(x: float, z: float) -> String:
		for id: String in g.world.loaded:
			var r: Dictionary = DmContent.area(id)["rect"]
			if x >= float(r["x0"]) and x <= float(r["x1"]) and z >= float(r["z0"]) and z <= float(r["z1"]):
				return id
		return ""
	var wrong_at := 0
	var wrong_interior := 0
	var edge_points: Array = []
	for id: String in g.world.loaded:
		var r2: Dictionary = DmContent.area(id)["rect"]
		for ex in [float(r2["x0"]), float(r2["x1"])]:
			for ez in [float(r2["z0"]), float(r2["z1"]), (float(r2["z0"]) + float(r2["z1"])) * 0.5]:
				edge_points.append(Vector2(ex, ez))
	for i in 3000:
		edge_points.append(Vector2(rng.randf_range(-250.0, 250.0), rng.randf_range(-250.0, 250.0)))
	for p: Vector2 in edge_points:
		var a: String = g.world.area_at(p.x, p.y)
		if a != walk.call(p.x, p.y):
			wrong_at += 1
	check(wrong_at == 0, "area_at answers what the walk over world.json's rects answers (3,000 random points and every edge; %d differ)" % wrong_at)
	var keyed := 0
	for id: String in g.world.loaded:
		var inner: PackedFloat64Array = g.world.area_interior(id)
		keyed += 1 if inner.size() == 4 else 0
		for k in 200:
			var x := rng.randf_range(inner[0], inner[1])
			var z := rng.randf_range(inner[2], inner[3])
			if x > inner[0] and x < inner[1] and z > inner[2] and z < inner[3] and (walk.call(x, z) != id or g.world.area_at(x, z) != id):
				wrong_interior += 1
	check(keyed == g.world.loaded.size() and wrong_interior == 0, "a point strictly inside an area's interior rect is in that area and no other (the %d loaded rects do not overlap; %d wrong)" % [keyed, wrong_interior])


# ------------------------------------------------------------------------------------------------------------------ the seals

func _the_seals() -> void:
	# a new character's open areas are the loaded ones whose world.json entry has no seal (unlock: null)
	var open_areas := _open_area_ids()
	var open_now: Array = g.world.unlocked.keys()
	open_now.sort()
	var open_sorted := open_areas.duplicate()
	open_sorted.sort()
	check(not open_areas.is_empty() and open_now == open_sorted, "a new character's open areas are the ones with no seal in world.json (%s)" % str(open_now))
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
	var map_ok := not map_doors.is_empty()
	var shown_open := 0
	for d: Dictionary in DmContent.doors():
		var both := open_areas.has(String(d["a"])) and open_areas.has(String(d["b"]))
		map_ok = map_ok and map_doors.get(String(d["id"]), not both) == both
		shown_open += 1 if both else 0
	check(map_ok and shown_open > 0 and shown_open < DmContent.doors().size() and map_doors.get("graves_warren", true) == false, "the minimap shows each door as the seals have it: the sealed ones closed (the Warren's among them), the hubs' open (%d open)" % shown_open)


# ------------------------------------------------------------------------------------------------------------------ the navmesh

func _the_navmesh() -> void:
	var core: RefCounted = g.core_host.core
	check(core.nav_triangle_count() > 0, "the core holds the navmesh's triangles (%d)" % core.nav_triangle_count())
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
	check(g.world.unlocked.size() == _open_area_ids().size() and _gate_closed("graves_warren"), "the seals are back")


# ------------------------------------------------------------------------------------------------------------------ breaking a seal

func _breaking_a_seal() -> void:
	var prog := g.ui_host.prog
	var u: Dictionary = DmContent.area("warren")["unlock"]
	prog.local["areaKills"][String(u["area"])] = prog.unlock_kills(float(u["kills"]))
	events.clear()
	var due := _opened_by(u)
	var broken: Array = g.chapterhouse.check_seals()
	broken.sort()
	check(broken == due and broken.has("warren"), "the %s's %d kills break the Warren's seal (%s)" % [String(u["area"]), prog.unlock_kills(float(u["kills"])), str(broken)])
	var banner := events.filter(func(e: Array) -> bool: return e[0] == "banner" and String(e[1].get("title", "")) == "A seal breaks")
	check(banner.size() == 1 and String(banner[0][1]["sub"]).contains(String(DmContent.area("warren")["name"]).trim_prefix("The ")), "the banner says so (%s)" % str(banner))
	check(_gate_open("graves_warren") and (g.world.nav_regions["area:warren"] as NavigationRegion3D).enabled, "the Warren's gate is up and its navmesh joins")
	var goal := g.world.nav_closest(_area_mid("warren"))
	var from := g.world.nav_closest(_area_mid("graves"))
	var hold := [PackedVector3Array()]
	await until(func() -> bool:   # the navigation server merges the opened regions on its own thread, a few frames later
		hold[0] = g.world.nav_path(from, goal)
		return hold[0].size() > 1 and g.world.area_at(hold[0][-1].x, hold[0][-1].z) == "warren", 600)
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
	g.chapterhouse.start_recall()   # 1.5 s of game time standing still
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


# ------------------------------------------------------------------------------------------------------------------ the Ossuary's kinds

func _the_ossuary() -> void:
	var prog := g.ui_host.prog
	var u: Dictionary = DmContent.area("ossuary")["unlock"]
	prog.local["areaKills"][String(u["area"])] = prog.unlock_kills(float(u["kills"]))
	var due := _opened_by(u)
	var broken: Array = g.chapterhouse.check_seals()
	broken.sort()
	check(broken == due and broken.has("ossuary"), "the %s's %d kills break the Ossuary's seal (%s)" % [String(u["area"]), prog.unlock_kills(float(u["kills"])), str(broken)])
	g.director.configure_area("ossuary")
	var roster: Array = DmContent.area("ossuary")["enemies"].map(func(e: Dictionary) -> String: return String(e["id"]))
	var kinds: Array = g.director.kinds.map(func(k: Dictionary) -> String: return String(k["id"]))
	check(kinds == roster and not roster.is_empty(), "the director makes the Ossuary's whole roster (%s)" % str(kinds))
	var theme: Dictionary = {}
	for th: Dictionary in DmSimData.WAVE_THEMES["ossuary"]:
		if th.get("lead") != null:
			theme = th
	var at := _area_mid("ossuary")
	var made_ids: Array = []
	check(not theme.is_empty(), "the Ossuary has a wave theme with a lead")
	g.director.rng.seed = 11   # (an elite lead could carry Hungering and eat the corpse below)
	var made: int = g.director.spawn_group(at + Vector3(float(DmSimData.WARD["range"]) * 0.5, 0, 0), [hero], 1, String(theme["lead"]), theme["roster"], made_ids)
	var golem: int = int(made_ids[0]) if not made_ids.is_empty() else 0   # (the lead: a golem today; any body will do for the blessing)
	var info: Dictionary = g.core_host.enemy_info(golem)
	check(made == 1 and info.get("def", "") == String(theme["lead"]) and info.get("area", "") == "ossuary", "%s leads with its %s, made in the Ossuary (%s)" % [String(theme["name"]), String(theme["lead"]), str(info.get("def", ""))])
	# A deacon of the director's, a corpse beside it and the lead wounded: it raises the corpse into a Risen of its level, then blesses the lead.
	var spawned: Array = []
	var tells: Array = []
	var cues: Array = []
	g.core_host.enemy_spawned.connect(func(id: int, d: String, lvl: int, _e: bool, a: String, _af: int, _x: float, _z: float, _h: float) -> void: spawned.append([id, d, lvl, a]))
	g.core_host.telegraph.connect(func(_id: int, tell: int, _fx: float, _fz: float, _ax: float, _az: float, _r: float, _s: float) -> void: tells.append(DmCoreEvents.TELLS[tell]))
	g.core_host.cue.connect(func(_id: int, kind: int, _x: float, _z: float, _r: float) -> void: cues.append(DmCoreEvents.CUES[kind]))
	events.clear()
	var deacon: int = g.director.spawn("deacon", at, [hero], false, {}, {"area": "ossuary"})
	var deacon_level := int(g.core_host.enemy_info(deacon).get("level", 0))
	var cid: int = g.core_host.corpses.add_corpse(at.x + 2.0, at.z, "normal", "robber", false, 0.0, 1.0, "ossuary")
	await ticks(ceili((DmSimConsts.RISE_TIME + 0.1) * 60.0))   # the lead has risen, so a blow can wound it
	check(not bool(g.core_host.enemy_info(golem).get("elite", true)), "(the lead is a plain one)")
	g.core_host.damage(golem, float(g.core_host.enemy_info(golem)["max_hp"]) * 0.5, 0, false)
	var risen := func() -> bool: return spawned.any(func(s: Array) -> bool: return s[1] == "risen")
	var raised := await until(risen, 60 * 12)
	check(deacon > 0 and cid > 0 and raised and tells.has(&"raise") and not tells.has(&"curse"), "the deacon raises the corpse: a raise telegraph, then a Risen (%s)" % str(tells))
	var r: Array = spawned.filter(func(s: Array) -> bool: return s[1] == "risen")
	check(not r.is_empty() and r[0][2] == deacon_level and r[0][3] == "ossuary", "the Risen has the deacon's level (%d) and area" % deacon_level)
	var blessed := await until(func() -> bool: return cues.has(&"sanctify"), 60 * 14)
	check(blessed and g.core_host.status_stacks(golem, "sanctified") == 1.0, "and blesses the wounded lead: the cue, and the status on it")
	check(events.any(func(e: Array) -> bool: return e[0] == "sanctify_near"), "the counsel hears of the Sanctify (sanctify_near)")
	for id in g.core_host.core.enemy_ids():
		g.core_host.remove_enemy(id)


# ------------------------------------------------------------------------------------------------------------------ the Nave's kinds

func _the_nave() -> void:
	var prog := g.ui_host.prog
	var u: Dictionary = DmContent.area("nave")["unlock"]
	prog.local["areaKills"][String(u["area"])] = prog.unlock_kills(float(u["kills"]))
	var broken: Array = g.chapterhouse.check_seals()
	var opened: Array = []     # every area the Ossuary's kills open at that count (the Nave's seal and the Coliseum's)
	for id in DmContent.area_order():
		var un: Variant = DmContent.area(String(id)).get("unlock")
		if un != null and String(un["area"]) == String(u["area"]) and float(un["kills"]) <= float(u["kills"]):
			opened.append(String(id))
	broken.sort()
	opened.sort()
	check(broken.has("nave") and broken == opened, "the Ossuary's %d kills break the Nave's seal (%s)" % [prog.unlock_kills(float(u["kills"])), str(broken)])
	g.director.configure_area("nave")
	var roster: Array = DmContent.area("nave")["enemies"].map(func(e: Dictionary) -> String: return String(e["id"]))
	var kinds: Array = g.director.kinds.map(func(k: Dictionary) -> String: return String(k["id"]))
	check(kinds == roster and not roster.is_empty(), "the director makes the Nave's whole roster (%s)" % str(kinds))
	var at := _area_mid("nave")
	var leads := {}
	var leads_ok := true
	var n := 0
	g.director.rng.seed = 11
	for th: Dictionary in DmSimData.WAVE_THEMES["nave"]:
		if th.get("lead") == null:
			continue
		var made_ids: Array = []
		var made: int = g.director.spawn_group(at + Vector3(3.0 + 6.0 * n, 0, 0), [hero], 1, String(th["lead"]), th["roster"], made_ids)
		var info: Dictionary = g.core_host.enemy_info(int(made_ids[0])) if not made_ids.is_empty() else {}
		leads[String(th["lead"])] = [made, String(info.get("def", "")), String(info.get("area", "")), String(th["name"])]
		leads_ok = leads_ok and made == 1 and String(info.get("def", "")) == String(th["lead"]) and String(info.get("area", "")) == "nave"
		n += 1
	check(n > 0 and leads_ok, "each wave theme of the Nave leads with its own kind, made in the Nave (%s)" % str(leads))
	for id in g.core_host.core.enemy_ids():
		g.core_host.remove_enemy(id)
	# The waystone takes him to the Nave now, to its stone on the open floor near the door.
	g.chapterhouse.travel("nave")
	await ticks(3)
	check(g.area_id == "nave", "the waystone takes him to the Nave, whose seal is broken (%s)" % g.area_id)
	var host := g.core_host
	var hp: Vector3 = hero.position
	var tells: Array = []
	var cues: Array = []
	var spawned: Array = []
	var corpses: Array = []
	host.telegraph.connect(func(_id: int, tell: int, _fx: float, _fz: float, _ax: float, _az: float, _r: float, _s: float) -> void: tells.append(DmCoreEvents.TELLS[tell]))
	host.cue.connect(func(_id: int, kind: int, _x: float, _z: float, _r: float) -> void: cues.append(DmCoreEvents.CUES[kind]))
	host.enemy_spawned.connect(func(id: int, d: String, lvl: int, _e: bool, a: String, _af: int, _x: float, _z: float, _h: float) -> void: spawned.append([id, d, lvl, a]))
	host.corpse_added.connect(func(id: int, _k: int, d: String, _e: bool, _a: String, _x: float, _z: float, _f: float, _s: float) -> void: corpses.append([id, d]))
	hero.restore_vitals()
	# The censer: its incense hastes the robber beside it and its cloud is up; the cloud goes with it.
	var censer: int = host.spawn_enemy("censer", hp + Vector3(-6.0, 0, -6.0), 1, 1.0, 0.0, false, "nave", false)
	var robber: int = host.spawn_enemy("robber", hp + Vector3(-6.0 - 0.4 * float(DmSimData.CENSER["radius"]), 0, -6.0), 1, 1.0, 0.0, false, "nave", false)   # inside the incense
	await ticks(4)
	check(host.status_stacks(robber, "incensed") == 1.0 and host.status_stacks(censer, "incensed") == 1.0 and g.enemy_fx._incense.has(censer), "the censer hastes the robber beside it and itself, and its cloud is drawn")
	host.damage(censer, 1.0e9, hero.core_id, false)
	await ticks(2)
	check(not g.enemy_fx._incense.has(censer), "its cloud goes with it")
	host.remove_enemy(robber)
	# The wraith sings at him and leaves no corpse; the gargoyle dives onto his place.
	hero.restore_vitals()
	var wraith: int = host.spawn_enemy("wraith", hp + Vector3(-2.0, 0, -8.0), 1, 1.0, 0.0, false, "nave", false)
	var gargoyle: int = host.spawn_enemy("gargoyle", hp + Vector3(-6.0, 0, -6.7), 1, 1.0, 0.0, false, "nave", false)
	var seen := await until(func() -> bool: return cues.has(&"scream") and cues.has(&"slam"), 60 * 12)
	check(seen and tells.has(&"scream") and tells.has(&"dive"), "the wraith's scream and the gargoyle's dive were announced, and both landed (%s)" % str(tells))
	check(host.enemy_alive(wraith) and host.enemy_alive(gargoyle), "(both stand)")
	host.damage(wraith, 1.0e9, hero.core_id, false)
	await ticks(3)
	check(not corpses.any(func(c: Array) -> bool: return c[1] == "wraith"), "and the wraith leaves no corpse")
	host.remove_enemy(gargoyle)
	# The templar: a blow from the front glances.
	var templar: int = host.spawn_enemy("templar", hp + Vector3(-1.0, 0, -5.0), 1, 1.0, 0.0, false, "nave", false)
	cues.clear()
	var before := float(host.enemy_info(templar)["hp"])
	host.damage(templar, 20.0, hero.core_id)
	await ticks(2)
	var passes := float(DmSimData.TEMPLAR_SHIELD["passThrough"])
	check(cues.has(&"shield_block") and absf((before - float(host.enemy_info(templar)["hp"])) - 20.0 * passes) < 1e-6, "the templar's shield glances a blow from the front: it costs %.0f%% (%.1f of 20)" % [passes * 100.0, before - float(host.enemy_info(templar)["hp"])])
	host.remove_enemy(templar)
	# The acolyte: the hero's thrall falls near it, killed; the acolyte claims the fall and a Risen climbs out of it with its level.
	hero.restore_vitals()
	var c := hero.get_node("Rites") as DmRiteCaster
	var ex := {"kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": c.mods["thrallAttackSpeedMult"], "r": 0.8}
	var fall := hp + Vector3(-6.0, 0, -2.0)           # a thrall rises where its corpse lies (not at the rite's aim): the corpse is here, inside Unbind's range of the acolyte
	var acolyte_at := hp + Vector3(-9.0, 0, -3.0)
	check(acolyte_at.distance_to(fall) < float(DmSimData.UNBIND["range"]), "(the corpse lies inside Unbind's range of the acolyte)")
	host.corpses.add_corpse(fall.x, fall.z, "normal", "robber", false, 0.0, 1.0, "nave")    # (a rite raises from a corpse)
	var joined := await until(func() -> bool: return _nav_joins(acolyte_at, fall), 60 * 5)
	check(joined, "the Nave's ground is in the navigation server's map: a path from the acolyte's place reaches the thrall's")
	var raised: Dictionary = c.thralls().raise(ex, fall)
	var acolyte: int = host.spawn_enemy("acolyte", acolyte_at, 3, 1.0, 0.0, false, "nave", false)
	var tid := int((raised["thralls"] as Array)[0]) if bool(raised["ok"]) else 0
	await ticks(ceili((DmSimConsts.THRALL_RISE_TIME + 0.1) * 60.0))   # the thrall has risen
	host.core.stun(tid, 1.0e6)
	await ticks(40)           # the acolyte has looked at it (every half second)
	cues.clear()
	spawned.clear()
	var ring_before := int(g.enemy_fx.stats["reach_ring"])
	host.core.kill_thrall(tid, "killed")
	var claimed := await until(func() -> bool: return cues.has(&"unbind"), 30)
	check(tid != 0 and acolyte > 0 and claimed, "the acolyte claims the thrall that was killed near it: Unbind's cue")
	var rose := await until(func() -> bool: return spawned.any(func(s: Array) -> bool: return s[1] == "risen"), 60 * 3)
	var r: Array = spawned.filter(func(s: Array) -> bool: return s[1] == "risen")
	check(rose and r[0][2] == 3 and r[0][3] == "nave", "and a Risen climbs out of it, at the acolyte's level (3), in the Nave")
	check(int(g.enemy_fx.stats["reach_ring"]) > ring_before or ring_before > 0, "the acolyte's reach ring was drawn while the thrall stood in it (%d)" % int(g.enemy_fx.stats["reach_ring"]))
	for id in g.core_host.core.enemy_ids():
		g.core_host.remove_enemy(id)
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------ the Sanctum's, the Coliseum's and the Cloister's kinds

func _the_late_areas() -> void:
	var prog := g.ui_host.prog
	# The Nave's kills break the Sanctum's seal and the Sanctum's the Cloister's; the Coliseum's broke with the Ossuary's (_the_nave).
	for area in ["sanctum", "cloister"]:
		var u: Dictionary = DmContent.area(area)["unlock"]
		prog.local["areaKills"][String(u["area"])] = prog.unlock_kills(float(u["kills"]))
		var broken: Array = g.chapterhouse.check_seals()
		check(broken.has(area), "the %s's %d kills break the %s's seal (%s)" % [String(u["area"]), prog.unlock_kills(float(u["kills"])), area, str(broken)])
	check(["coliseum", "sanctum", "cloister"].all(func(a: String) -> bool: return prog.really_unlocked(a)), "the Coliseum, the Sanctum and the Cloister are open")
	# The director makes each one's whole roster, and each wave theme leads with its own kind.
	var leads := {}
	var leads_ok := true
	var n := 0
	for area in ["coliseum", "sanctum", "cloister"]:
		g.director.configure_area(area)
		var roster: Array = DmContent.area(area)["enemies"].map(func(e: Dictionary) -> String: return String(e["id"]))
		var kinds: Array = g.director.kinds.map(func(k: Dictionary) -> String: return String(k["id"]))
		check(kinds == roster and not roster.is_empty(), "the director makes the %s's whole roster (%s)" % [area, str(kinds)])
		g.director.rng.seed = 11
		for th: Dictionary in DmSimData.WAVE_THEMES.get(area, []):
			if th.get("lead") == null:
				continue
			var made_ids: Array = []
			var made: int = g.director.spawn_group(_area_mid(area) + Vector3(3.0 + 6.0 * n, 0, 0), [hero], 1, String(th["lead"]), th["roster"], made_ids)
			var info: Dictionary = g.core_host.enemy_info(int(made_ids[0])) if not made_ids.is_empty() else {}
			leads[area + "/" + String(th["name"])] = [made, String(info.get("def", "")), String(info.get("area", ""))]
			leads_ok = leads_ok and made == 1 and String(info.get("def", "")) == String(th["lead"]) and String(info.get("area", "")) == area
			n += 1
	check(n > 0 and leads_ok, "every wave theme of the Coliseum, the Sanctum and the Cloister leads with its own kind, made in its own area (%s)" % str(leads))
	for id in g.core_host.core.enemy_ids():
		g.core_host.remove_enemy(id)
	# The waystone takes him to the Sanctum.
	_break_seal("sanctum")
	g.chapterhouse.travel("sanctum")
	await ticks(3)
	check(g.area_id == "sanctum", "the waystone takes him to the Sanctum, whose seal is broken (%s)" % g.area_id)
	var host := g.core_host
	var hp: Vector3 = hero.position
	var tells: Array = []
	var cues: Array = []
	var zones: Array = []
	host.telegraph.connect(func(_id: int, tell: int, _fx: float, _fz: float, _ax: float, _az: float, _r: float, _s: float) -> void: tells.append(DmCoreEvents.TELLS[tell]))
	host.cue.connect(func(_id: int, kind: int, _x: float, _z: float, _r: float) -> void: cues.append(DmCoreEvents.CUES[kind]))
	host.zone.connect(func(_id: int, k: int, _s: int, _x: float, _z: float, _r: float, _t: float) -> void: zones.append(DmCoreEvents.ZONE_KINDS[k]))
	hero.restore_vitals()
	# The seraph, well off (out of reach of its curse), with a robber beside it: the ward comes first, with the cue and the status, and the counsel hears of the Sanctify.
	events.clear()
	var seraph := 0
	var friend := 0
	var safe_from_curse := float(DmSimData.ENEMIES["seraph"]["attackRange"]) + 3.5   # beyond its curse's reach, with room to spare
	for unit in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var dir: Vector3 = unit * (safe_from_curse + 2.0)
		seraph = host.spawn_enemy("seraph", hp + dir, 1, 1.0, 1.0, false, "sanctum", false)
		friend = host.spawn_enemy("robber", hp + dir + Vector3(2.0, 0, 0), 1, 1.0, 0.0, false, "sanctum", false)
		await ticks(2)
		var away := Vector2(host.enemy_info(seraph)["pos"]).distance_to(Vector2(hp.x, hp.z))
		if away >= safe_from_curse:
			break
		host.remove_enemy(seraph)
		host.remove_enemy(friend)
		seraph = 0
	check(seraph != 0, "(a seraph stands %.1f m or more from him)" % safe_from_curse)
	host.damage(friend, float(host.enemy_info(friend)["max_hp"]) * 0.3, hero.core_id, false)
	var warded := await until(func() -> bool: return cues.has(&"sanctify"), 60 * 4)
	check(warded and host.status_stacks(friend, "sanctified") == 1.0 and not tells.has(&"curse"), "the seraph's ward blesses the robber beside it before it is in reach of him: the cue, the status, no curse yet")
	check(events.any(func(e: Array) -> bool: return e[0] == "sanctify_near"), "the counsel hears of the Sanctify (sanctify_near)")
	for id in host.core.enemy_ids():
		host.remove_enemy(id)
	await ticks(2)
	# The Cloister: the plague doctor's flask is announced and lands with its pool; a wounded flagellant is frenzied and sheds its motes.
	_break_seal("cloister")      # (the character's progress has been refreshed from the test server since: it holds the kills the server knows)
	g.chapterhouse.travel("cloister")
	await ticks(3)
	check(g.area_id == "cloister", "the waystone takes him to the Cloister, whose seal is broken (%s)" % g.area_id)
	hp = hero.position
	hero.restore_vitals()
	tells.clear()
	cues.clear()
	zones.clear()
	var fx_before: Dictionary = g.enemy_fx.stats.duplicate()
	var doctor: int = host.spawn_enemy("plague_doctor", hp + Vector3(-1.0, 0, -6.0), 1, 1.0, 1.0, false, "cloister", false)
	var lands := await until(func() -> bool: return cues.has(&"flask"), 60 * 12)
	check(lands and tells.has(&"flask") and zones.has(&"toxic"), "the plague doctor's flask was announced (a ring), landed (its cue) and left a toxic pool (%s)" % str(tells))
	check(g.enemy_fx.stats["telegraph"] > int(fx_before["telegraph"]) and g.enemy_fx.stats["strike"] > int(fx_before["strike"]), "DmEnemyFx drew the flask's ring and its landing")
	host.remove_enemy(doctor)
	hero.restore_vitals()
	var fl: int = host.spawn_enemy("flagellant", hp + Vector3(3.0, 0, -4.0), 1, 1.0, 0.0, false, "cloister", false)
	await ticks(3)
	var motes := int(g.enemy_fx.stats["status_mote"])
	var frenzy: Dictionary = DmSimData.FRENZY
	host.damage(fl, float(host.enemy_info(fl)["max_hp"]) * (1.0 - 0.5 * float(frenzy["atFrac"])), hero.core_id, false)   # to half of the health at which the frenzy starts
	await ticks(60)
	check(host.status_stacks(fl, "frenzy") == 1.0 and absf(float(host.enemy_info(fl)["speed_mult"]) - float(frenzy["moveMult"])) < 1e-9, "a flagellant under %.0f%% health is frenzied (x%.2f feet)" % [float(frenzy["atFrac"]) * 100.0, float(frenzy["moveMult"])])
	check(int(g.enemy_fx.stats["status_mote"]) > motes, "and sheds blood motes near him (%d)" % (int(g.enemy_fx.stats["status_mote"]) - motes))
	for id in host.core.enemy_ids():
		host.remove_enemy(id)
	await ticks(2)


## Breaks an area's seal by the kills it asks of the area before it (again, when the character's progress was refreshed since).
func _break_seal(area: String) -> void:
	var prog := g.ui_host.prog
	var u: Dictionary = DmContent.area(area)["unlock"]
	prog.local["areaKills"][String(u["area"])] = prog.unlock_kills(float(u["kills"]))
	g.chapterhouse.check_seals()


# ------------------------------------------------------------------------------------------------------------------ the Pyre's and the Fen's kinds

func _the_pyre_and_fen() -> void:
	# Home first (the recall is T; its arrival is a progress sync), then the seals.
	g.chapterhouse.start_recall()
	await until(func() -> bool: return not g.chapterhouse.recall_active, 60 * 120)
	await ticks(3)
	var prog := g.ui_host.prog
	var pu: Dictionary = DmContent.area("pyre")["unlock"]
	prog.local["areaKills"][String(pu["area"])] = prog.unlock_kills(float(pu["kills"]))
	var broken: Array = g.chapterhouse.check_seals()
	check(broken.has("pyre"), "the Cloister's %d kills break the Pyre's seal (%s)" % [prog.unlock_kills(float(pu["kills"])), str(broken)])
	var fu: Dictionary = DmContent.area("fen")["unlock"]
	prog.local["areaKills"][String(fu["area"])] = prog.unlock_kills(float(fu["kills"]))
	broken = g.chapterhouse.check_seals()
	check(broken.has("fen"), "the Pyre's %d kills break the Fen's seal (%s)" % [prog.unlock_kills(float(fu["kills"])), str(broken)])
	# The director makes both rosters whole, and leads each of the Fen's wave themes with its own kind.
	var rosters := {}   # area -> the kinds of its roster, for the idle-tell checks below
	for area: String in ["pyre", "fen"]:
		g.director.configure_area(area)
		var roster: Array = DmContent.area(area)["enemies"].map(func(e: Dictionary) -> String: return String(e["id"]))
		var kinds: Array = g.director.kinds.map(func(k: Dictionary) -> String: return String(k["id"]))
		check(kinds == roster and not roster.is_empty(), "the director makes the %s's whole roster (%s)" % [area, str(kinds)])
		rosters[area] = roster
	var pyre_kinds: Array = rosters["pyre"]
	var fen_kinds: Array = rosters["fen"]
	var at := _area_mid("fen")
	var leads := {}
	var leads_ok := true
	var n := 0
	g.director.rng.seed = 11
	for th: Dictionary in DmSimData.WAVE_THEMES["fen"]:
		if th.get("lead") == null:
			continue
		var made_ids: Array = []
		var made: int = g.director.spawn_group(at + Vector3(3.0 + 6.0 * n, 0, 0), [hero], 1, String(th["lead"]), th["roster"], made_ids)
		var info: Dictionary = g.core_host.enemy_info(int(made_ids[0])) if not made_ids.is_empty() else {}
		leads[String(th["name"])] = [made, String(info.get("def", "")), String(info.get("area", ""))]
		leads_ok = leads_ok and made == 1 and String(info.get("def", "")) == String(th["lead"]) and String(info.get("area", "")) == "fen"
		n += 1
	check(n > 0 and leads_ok, "each wave theme of the Fen leads with its own kind, made in the Fen (%s)" % str(leads))
	for id in g.core_host.core.enemy_ids():
		g.core_host.remove_enemy(id)
	# The waystone to the Pyre.
	g.chapterhouse.travel("pyre")
	await ticks(3)
	check(g.area_id == "pyre", "the waystone takes him to the Pyre, whose seal is broken (%s)" % g.area_id)
	var host := g.core_host
	var tells: Array = []
	var zones: Array = []
	var effects: Array = []
	host.telegraph.connect(func(_id: int, tell: int, _fx: float, _fz: float, _ax: float, _az: float, _r: float, _s: float) -> void: tells.append(DmCoreEvents.TELLS[tell]))
	host.zone.connect(func(id: int, kind: int, source: int, _x: float, _z: float, _r: float, _s: float) -> void: zones.append([id, DmCoreEvents.ZONE_KINDS[kind], source]))
	host.target_effect.connect(func(_id: int, _target: int, effect: int, seconds: float, x: float, z: float) -> void: effects.append([DmCoreEvents.EFFECTS[effect], seconds, Vector2(x, z)]))
	var hp: Vector3 = hero.position
	hero.restore_vitals()
	# The Husk falls beside him: its embers burst, the pool is drawn and burns him once a second, and burns out.
	var burn0 := int(g.hits_taken.get("burn", 0))
	var zone0 := int(g.enemy_fx.stats["zone"])
	var husk: int = host.spawn_enemy("cinder_husk", hp + Vector3(1.0, 0, 0), 1, 1.0, 1.0, false, "pyre", false)
	await ticks(2)
	host.damage(husk, 1.0e9, hero.core_id, false)
	await ticks(3)
	check(zones.any(func(z: Array) -> bool: return z[1] == &"ember" and z[2] == husk) and int(g.enemy_fx.stats["zone"]) == zone0 + 1 and g.enemy_fx._zones.size() == 1, "the Husk's last embers are a pool of kind ember, and the fx drew it")
	var pool_s := float(DmSimData.EMBER_DEATH["poolS"])
	await ticks(130)   # 2.2 s of the pool, or what is left of it
	var burns_due := maxi(1, int(minf(pool_s - 0.5, 2.0)))   # a burn a second while the pool lasts
	check(int(g.hits_taken.get("burn", 0)) >= burn0 + burns_due, "and it burns him once a second (%d burns in 2 s, %d due)" % [int(g.hits_taken.get("burn", 0)) - burn0, burns_due])
	check(await until(func() -> bool: return g.enemy_fx._zones.is_empty(), 60 * int(ceil(pool_s + 2.0))), "and burns out: the pool's visual goes with it")
	# The Priest throws a coal at him: the ring, the blow as ember, and a pool where it landed.
	hero.restore_vitals()
	zones.clear()
	tells.clear()
	var ember0 := int(g.hits_taken.get("ember", 0))
	var priest: int = host.spawn_enemy("pyre_priest", hp + Vector3(0.0, 0, -7.5), 1, 1.0, 1.0, false, "pyre", false)
	var threw := await until(func() -> bool: return zones.any(func(z: Array) -> bool: return z[2] == priest), 60 * 12)
	check(threw and tells.has(&"ember") and int(g.hits_taken.get("ember", 0)) > ember0, "the Priest's coal was announced, hit him as ember and left a pool (%s)" % str(tells))
	host.remove_enemy(priest)
	# The Slag Brute slams: a molten ring, the blow, and a pool on the ring.
	hero.restore_vitals()
	zones.clear()
	tells.clear()
	var brute: int = host.spawn_enemy("slag_brute", hp + Vector3(3.0, 0, 0), 1, 1.0, 1.0, false, "pyre", false)
	var slammed := await until(func() -> bool: return zones.any(func(z: Array) -> bool: return z[2] == brute), 60 * 12)
	check(slammed and tells.has(&"slam"), "the Slag Brute's slam was announced and left a pool (%s)" % str(tells))
	host.remove_enemy(brute)
	# The Pyre's dead shed embers near him (the idle tells).
	for id in g.core_host.core.enemy_ids():
		host.remove_enemy(id)
	hero.restore_vitals()
	var motes0 := int(g.enemy_fx.stats["pf_mote"])
	for k in pyre_kinds:
		host.spawn_enemy(k, hp + Vector3(6.0 + 0.5 * pyre_kinds.find(k), 0, 6.0), 1, 1.0, 0.0, false, "pyre", false)
	await ticks(150)
	check(int(g.enemy_fx.stats["pf_mote"]) > motes0, "the Pyre's dead shed embers and soot near him (%d motes in 2.5 s)" % (int(g.enemy_fx.stats["pf_mote"]) - motes0))
	for id in g.core_host.core.enemy_ids():
		host.remove_enemy(id)
	await ticks(2)
	check(g.enemy_fx._pfs.is_empty(), "and the fx holds nothing for them once they are gone")
	# The Fen, from the Pyre's stone.
	g.chapterhouse.travel("fen")
	await ticks(3)
	check(g.area_id == "fen", "the waystone takes him to the Fen, whose seal is broken (%s)" % g.area_id)
	hp = hero.position
	hero.restore_vitals()
	var st: DmStatusSet = DmStatusSet.ensure(hero)
	# The Hag hexes him: the ring, the curse, and a chill on him.
	tells.clear()
	effects.clear()
	var curse0 := int(g.hits_taken.get("curse", 0))
	var hag: int = host.spawn_enemy("bog_hag", hp + Vector3(0.0, 0, -8.0), 1, 1.0, 1.0, false, "fen", false)
	var hexed := await until(func() -> bool: return effects.any(func(e: Array) -> bool: return e[0] == &"chill"), 60 * 12)
	check(hexed and tells.has(&"hex") and int(g.hits_taken.get("curse", 0)) > curse0 and st.has(&"chill"), "the Hag's hex was announced, cursed him and chilled him (%s)" % str(tells))
	check(absf(float(effects.filter(func(e: Array) -> bool: return e[0] == &"chill")[0][1]) - float(DmSimData.HAG_HEX["chillMs"]) / 1000.0) < 1e-4, "for the hex's %.1f s" % (float(DmSimData.HAG_HEX["chillMs"]) / 1000.0))
	host.remove_enemy(hag)
	# The Wisp pulses: the ring, the cold, and a chill on him. (It keeps its distance and backs off toward the water.)
	hero.restore_vitals()
	st.remove(&"chill")
	tells.clear()
	effects.clear()
	var dust0 := int(g.hits_taken.get("dust", 0))
	var wisp: int = host.spawn_enemy("fen_wisp", hp + Vector3(0.0, 0, -7.5), 1, 1.0, 1.0, false, "fen", false)
	var pulsed := await until(func() -> bool: return effects.any(func(e: Array) -> bool: return e[0] == &"chill"), 60 * 12)
	check(pulsed and tells.has(&"pulse") and int(g.hits_taken.get("dust", 0)) > dust0 and st.has(&"chill"), "the Wisp's pulse was announced, hit him and chilled him (%s)" % str(tells))
	host.remove_enemy(wisp)
	# The Sexton throws the chain: along the line, the blow, the drag toward it and the root.
	hero.restore_vitals()
	st.remove(&"chill")
	tells.clear()
	effects.clear()
	var sexton: int = host.spawn_enemy("drowned_sexton", hp + Vector3(-7.0, 0, 0.0), 1, 1.0, 1.0, false, "fen", false)    # (west, along the land: the line between them must stay on the navmesh)
	host.core.apply_status(sexton, "root", 0, 1.0, 1000.0)    # (it stands, so the drag is measured from where it is)
	var before := hero.position
	var hooked := await until(func() -> bool: return effects.any(func(e: Array) -> bool: return e[0] == &"pull"), 60 * 12)
	check(hooked and tells.has(&"hook") and effects.any(func(e: Array) -> bool: return e[0] == &"root"), "the Sexton's chain was announced and dragged and rooted him (%s)" % str(effects.map(func(e: Array) -> StringName: return e[0])))
	check(st.has(&"root"), "he is rooted (the status is on his body)")
	await ticks(40)
	var sx: Vector3 = hp + Vector3(-7.0, 0, 0.0)
	check(hero.position.distance_to(sx) < before.distance_to(sx) - 2.0, "he was dragged toward it: %.1f m from the sexton, from %.1f" % [hero.position.distance_to(sx), before.distance_to(sx)])
	host.remove_enemy(sexton)
	# The Leech bites with rot.
	hero.restore_vitals()
	var toxic0 := int(g.hits_taken.get("toxic", 0))
	var leech: int = host.spawn_enemy("mire_leech", hp + Vector3(0.0, 0, -4.0), 1, 1.0, 1.0, false, "fen", false)
	check(await until(func() -> bool: return int(g.hits_taken.get("toxic", 0)) > toxic0, 60 * 8), "the Leech's bite reaches him as toxic")
	host.remove_enemy(leech)
	var motes1 := int(g.enemy_fx.stats["pf_mote"])
	for k in fen_kinds:
		host.spawn_enemy(k, hp + Vector3(6.0, 0, 6.0 + 0.5 * fen_kinds.find(k)), 1, 1.0, 0.0, false, "fen", false)
	await ticks(150)
	check(int(g.enemy_fx.stats["pf_mote"]) > motes1, "the Fen's dead shed marsh-lights and drips near him (%d motes in 2.5 s)" % (int(g.enemy_fx.stats["pf_mote"]) - motes1))
	for id in g.core_host.core.enemy_ids():
		host.remove_enemy(id)
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------ waves follow the hero

## Today's director: the waves come to whatever combat area a hero stands in, and the ground left behind is cleared at once (its living bodies sent away: no
## death, corpse or credit) so the global cap is free for the new one (Helix's playtest, 2026-10-17: once the Graves' bodies filled the cap, no wave came anywhere else).
func _waves_follow_the_hero() -> void:
	g.world.set_unlocked(DmNextWorld.every_area())
	hero.p["god"] = true
	var made := {}
	var gone: Array = []
	g.core_host.enemy_spawned.connect(func(_id: int, _d: String, _l: int, _e: bool, a: String, _af: int, _x: float, _z: float, _h: float) -> void: made[a] = int(made.get(a, 0)) + 1)
	g.core_host.enemy_removed.connect(func(id: int) -> void: gone.append(id))
	g.director.enabled = true
	var cap := int(DmSimData.GLOBAL_ENEMY_CAP)
	var stays: Array = []   # the bodies made in each stay but the last, which the next arrival sends away
	var stay_areas: Array[String] = ["graves", "ossuary", "nave", "graves"]
	for area: String in stay_areas:
		hero.teleport(g.world.nav_closest(_area_mid(area)))
		var from := int(made.get(area, 0))
		var wanted := int(DmContent.area(area)["cap"])
		var share := mini(wanted, cap) * 3 / 4
		var a_def: Dictionary = DmContent.area(area)
		var waves_due := ceili(float(share) / float(a_def["waveSize"]))   # the waves that bring that many, one every waveIntervalMs
		var wait_s := maxf(40.0, float(waves_due + 1) * float(a_def["waveIntervalMs"]) / 1000.0 + 20.0)
		var ok := await until(func() -> bool: return int(made.get(area, 0)) - from >= share, int(wait_s * 60.0))
		var others := 0
		for id in g.core_host.core.enemy_ids():
			var info: Dictionary = g.core_host.core.enemy_info(id)
			if String(info.get("area", "")) != area and int(info["state"]) != DmCoreEvents.State.DEAD:
				others += 1
		check(ok and g.director.area_id == area, "waves come to the hero in the %s (%d made there, the director on %s)" % [area, int(made.get(area, 0)) - from, g.director.area_id])
		check(others == 0, "the ground left behind holds no living body (%d)" % others)
		stays.append(int(made.get(area, 0)) - from)
	var left_behind := 0
	for i in stays.size() - 1:
		left_behind += int(stays[i])
	check(gone.size() >= left_behind and left_behind > 0, "the bodies left behind were sent away (%d gone, %d made in the stays before the last)" % [gone.size(), left_behind])
	g.director.enabled = false
	hero.p["god"] = false


# ------------------------------------------------------------------------------------------------------------------ waves in two areas

## A second player's body in the host's session: its roster entry and the spawner's body, as a joiner's (the director only reads where the party's bodies stand). Not an external of the core, so
## no enemy fights it; `_remove_mate` takes it out again.
func _add_mate(id: int) -> DmHeroBody:
	g.session._accept(id, "mate", "gravecaller")
	return g.body_of(id)


func _remove_mate(id: int) -> void:
	g.session._remove_player(id)
	_pins.erase(id)


## A body put at `at` and held there: an enemy's drag or a shove must not walk a player out of the area a scene is about to read (the director goes by where the players stand).
func _put(id: int, at: Vector3) -> void:
	g.body_of(id).teleport(at)
	_pins[id] = at


func _hold_pins(_dt: float) -> void:
	for id: int in _pins:
		var b := g.body_of(id)
		if b != null and b.position.distance_to(_pins[id]) > 0.5:
			b.teleport(_pins[id])


## The living bodies of the core by the area they belong to (the area tag of the body, which is where the director sent them).
func _alive_by_area() -> Dictionary:
	var out := {}
	for id in g.core_host.core.enemy_ids():
		var info: Dictionary = g.core_host.core.enemy_info(id)
		if int(info["state"]) != DmCoreEvents.State.DEAD:
			out[String(info["area"])] = int(out.get(String(info["area"]), 0)) + 1
	return out


## Plays `seconds` of game time with the director on, sampling the core every tick: returns the most bodies the core held at once (the dying counted) and, per area, the most living ones.
func _watch_waves(seconds: float, until_cond: Callable = Callable()) -> Dictionary:
	var out := {"total": 0, "by_area": {}}
	for _t in int(seconds * 60.0):
		await physics_frame
		out["total"] = maxi(int(out["total"]), g.core_host.enemy_total())
		var by: Dictionary = _alive_by_area()
		for a: String in by:
			out["by_area"][a] = maxi(int(out["by_area"].get(a, 0)), int(by[a]))
		if until_cond.is_valid() and bool(until_cond.call()):
			break
	return out


func _clear_field() -> void:
	for id in g.core_host.core.enemy_ids():
		g.core_host.remove_enemy(id)
	await ticks(3)


## Each area a party member stands in gets its own waves (Helix's 2026-10-20 list: "only the host's area gets waves"). The host stands in the Graves and a member in the Ossuary, neither fights,
## so nothing dies and the counts are the director's alone: the numbers are the areas' own (cap, wave size, interval) and the Wave Speed tier's, read from the game's data.
func _waves_in_two_areas() -> void:
	var d := g.director
	var host := g.core_host
	var global_cap := int(DmSimData.GLOBAL_ENEMY_CAP)
	var home := "graves"
	var away := "ossuary"
	var surge: DmGraveSurge = d.surge
	d.surge = null   # (a surge adds bodies of its own: client/tests/surge.gd plays them)
	d.enabled = false
	await _clear_field()
	g.world.set_unlocked(DmNextWorld.every_area())
	hero.p["god"] = true
	_put(1, g.world.nav_closest(_area_mid(home)))
	var mate := _add_mate(7)
	host.ticked.connect(_hold_pins)
	check(mate != null and g.session.get_bodies().size() == 2, "a second player stands in the host's session")
	var spawns: Array = []   ## [area, x, z, level] of every body made
	var on_spawn := func(_id: int, _d: String, level: int, _e: bool, a: String, _af: int, x: float, z: float, _h: float) -> void: spawns.append([a, x, z, level])
	host.enemy_spawned.connect(on_spawn)
	var of_away := func(sp: Array) -> bool: return sp[0] == away
	# together: the Graves hold both heroes, one clock and one cap, and no other area is touched
	var home_def: Dictionary = DmContent.area(home)
	var home_cap := int(home_def["cap"])
	var fill_s: float = (ceil(float(home_cap) / float(home_def["waveSize"])) + 2.0) * float(home_def["waveIntervalMs"]) / 1000.0 + 5.0   # the waves that bring a full cap, and one more
	_put(7, g.world.nav_closest(_area_mid(home) + Vector3(3.0, 0.0, 0.0)))
	d.configure_area(home)
	d.enabled = true
	var together := await _watch_waves(fill_s)
	check(int(together["by_area"].get(home, 0)) == mini(home_cap, global_cap) and not spawns.any(of_away),
		"two heroes in the Graves share one clock and one cap (%d living, the area's cap %d), nothing is made elsewhere" % [int(together["by_area"].get(home, 0)), home_cap])
	check(int(together["total"]) <= global_cap, "and never more than the global cap (%d of %d)" % [int(together["total"]), global_cap])
	# apart: the member walks into the Ossuary. The Wave Speed tier lifts both areas' caps over half the global cap, so the shared limit is what binds
	d.enabled = false
	await _clear_field()
	spawns.clear()
	var tier := 6.0
	d.set_wave_tier(tier)
	var cap_mult := float(DmWaveUpgrades.wave_modifiers(tier)["capMult"])
	var share := global_cap / 2
	var home_room := DmMath.js_round(float(home_cap) * cap_mult)
	var away_room := DmMath.js_round(float(DmContent.area(away)["cap"]) * cap_mult)
	check(home_room > share and away_room > share, "(at Wave Speed %d each area's own cap, %d and %d, is over half the global cap of %d)" % [int(tier), home_room, away_room, global_cap])
	_put(1, g.world.nav_closest(_area_mid(home)))
	_put(7, g.world.nav_closest(_area_mid(away)))
	d.configure_area(home)
	d.enabled = true
	var seen := await _watch_waves(120.0, func() -> bool:
		var by := _alive_by_area()
		return int(by.get(home, 0)) >= share and int(by.get(away, 0)) >= share)
	check(spawns.any(of_away), "the Ossuary gets waves while the host fights in the Graves (%d bodies made there)" % spawns.filter(of_away).size())
	check(int(seen["by_area"].get(home, 0)) == share and int(seen["by_area"].get(away, 0)) == share,
		"each area fills to its half of the global cap and no more (%s, half is %d)" % [str(seen["by_area"]), share])
	check(int(seen["total"]) <= global_cap and host.enemy_total() <= global_cap, "the global cap is shared, not doubled: %d bodies at most (the cap is %d)" % [int(seen["total"]), global_cap])
	var placed := true
	var levels_ok := true
	var want_level := int(DmEnemyStats.area_level(away, d.scaling_levels([mate]), float(d.vow_fx.get("levels", 0.0)), 1.0))
	for sp: Array in spawns:
		var rect: Dictionary = DmContent.area(String(sp[0]))["rect"]
		var inside := float(sp[1]) >= float(rect["x0"]) - 2.5 and float(sp[1]) <= float(rect["x1"]) + 2.5 and float(sp[2]) >= float(rect["z0"]) - 2.5 and float(sp[2]) <= float(rect["z1"]) + 2.5
		var around: Vector3 = mate.position if sp[0] == away else hero.position
		var dist := Vector2(float(sp[1]) - around.x, float(sp[2]) - around.z).length()
		placed = placed and inside and dist <= DmWaveDirector.SPAWN_MAX + 3.0
		if sp[0] == away:
			levels_ok = levels_ok and int(sp[3]) == want_level
	check(placed, "every body climbs in inside its own area, around the player standing there (%d bodies)" % spawns.size())
	check(levels_ok and want_level >= 1, "the Ossuary's bodies are the Ossuary's level for the party's leader (%d)" % want_level)
	var idle_two := _idle_tick_us(d)
	# the member leaves for the hub: the Ossuary has nobody, so its bodies go after EMPTY_CLEAR_S and the Graves' stay
	spawns.clear()
	_put(7, g.world.spawn_point())
	await ticks(int((DmWaveDirector.EMPTY_CLEAR_S - 3.0) * 60.0))
	var before := _alive_by_area()
	check(int(before.get(away, 0)) == share and int(before.get(home, 0)) >= share, "the Ossuary is kept for a while after its member left (%s)" % str(before))
	await ticks(5 * 60)
	var after := _alive_by_area()
	check(int(after.get(away, 0)) == 0 and int(after.get(home, 0)) >= share, "after %d s its bodies are sent away and the Graves' stay (%s)" % [int(DmWaveDirector.EMPTY_CLEAR_S), str(after)])
	check(not spawns.any(of_away), "and nothing new climbs into the empty Ossuary")
	print("INFO world: the director's idle tick, party sorted into its areas: %.1f us with two areas in play, %.1f us with one" % [idle_two, _idle_tick_us(d)])
	# the member comes back and the host goes home: the director moves to the member's area, the Graves' bodies go at once and the member's clock goes on
	_put(7, g.world.nav_closest(_area_mid(away)))
	await ticks(4 * 60)
	check(d.area_id == home and int(_alive_by_area().get(away, 0)) > 0, "the member is back in the Ossuary: it has waves again, and the director stays in the Graves")
	var followed: Array[String] = []
	d.area_followed.connect(func(a: String) -> void: followed.append(a))
	var clock_there: float = d._extra[0].since_arrival
	var clock_here: float = d._since_arrival
	_put(1, g.world.spawn_point())
	await ticks(5)
	var now := _alive_by_area()
	check(followed.size() == 1 and followed[0] == away and d.area_id == away and int(now.get(home, 0)) == 0 and int(now.get(away, 0)) > 0,
		"the host goes home: the director moves to the Ossuary, the Graves' bodies are sent away at once and the Ossuary's stay (%s, on %s)" % [str(now), d.area_id])
	check(d._since_arrival >= clock_there and clock_there > 0.0 and d._since_arrival < clock_here, "and the Ossuary's own wave clock goes on, neither starting over nor the Graves' (%.1f s in, %.1f s before; the Graves' was at %.1f s)" % [d._since_arrival, clock_there, clock_here])
	# the party disbands
	host.enemy_spawned.disconnect(on_spawn)
	host.ticked.disconnect(_hold_pins)
	_pins.clear()
	d.enabled = false
	d.set_wave_tier(0.0)
	d.surge = surge
	_remove_mate(7)
	await _clear_field()
	hero.p["god"] = false
	hero.teleport(g.world.spawn_point())
	await ticks(5)
	check(g.session.get_bodies().size() == 1, "the second player is gone again")


## Microseconds one idle tick of the director takes (the party sorted into its grounds, no wave due): printed, never judged (a clock is not a test).
func _idle_tick_us(d: DmWaveDirector) -> float:
	var n := 300
	var t0 := Time.get_ticks_usec()
	for _i in n:
		d._physics_process(0.0)
	return float(Time.get_ticks_usec() - t0) / float(n)
