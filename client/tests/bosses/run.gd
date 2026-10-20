extends SceneTree
## Headless: godot --headless --path client --script res://tests/bosses/run.gd
## Replays every scenario in tests/bosses/fixtures (*.json.gz, captured from the real TS BossBrain; committed answer keys) through the
## GDScript brains and compares, per tick: the boss state, the ordered world-call log (events, spawns, pools, removals) and the
## entities left in the world. First mismatch per scenario is reported. The one place the recorded scenarios are replayed (boss.gd and the boss_* suites do not).
## The recordings are of the retired TS brains with the boss data of the day, so the data the brains read is put back as it was (fixtures/recorded_data.json, the exports of bosses, fen, abilities, difficulty,
## the Seal's EMPOWER and the areas' levels) for this run: retuning the boss data in the game never breaks a recording, and a recording is only ever compared with the numbers it was made with.

const FX := "res://tests/bosses/fixtures/"
const RECORDED_DATA := "res://tests/bosses/fixtures/recorded_data.json"
const Brains := preload("res://sim/bosses/boss_brains.gd")
const FakeWorld := preload("res://tests/bosses/fake_world.gd")
const DeepDiff := preload("res://tests/bosses/deep_diff.gd")

var pass_n := 0
var fail_n := 0


## The data the brains read, as it was when the scenarios were recorded, into the registry's cache ({<DmDb path>: {<export>: value}}): `Content.get_export` serves it to every brain made after this.
func _freeze_data() -> bool:
	var snap: Variant = JSON.parse_string(FileAccess.get_file_as_string(RECORDED_DATA))
	if not snap is Dictionary:
		return false
	for rel: String in snap:
		var node: Dictionary = DmDb.raw(rel)
		for key: String in snap[rel]:
			node[key] = snap[rel][key]
	return true


func _init() -> void:
	ok(_freeze_data(), "the data of the recordings is there (fixtures/recorded_data.json)")
	var dir := DirAccess.open(FX)
	var files: Array = []
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".json.gz"):
				files.append(f)
	if files.is_empty():
		printerr("fixtures missing: fixtures are committed: tests/bosses/fixtures/*.json.gz")
		print("bosses: 0 passed, 1 failed")
		print("FAIL bosses: no recorded scenarios")
		quit(1)
		return
	files.sort()
	# every recording is of a boss of the data (the recordings come from the retired TS brains, so a boss added since has none and needs none here; the boss_* suites and boss.gd test the scenes)
	var orphans: Array = files.filter(func(f: String) -> bool: return not Brains.BOSS_IDS.any(func(id: String) -> bool: return f.begins_with(id + "_")))
	ok(orphans.is_empty(), "every recorded scenario is of a boss the data names (not: %s)" % str(orphans))
	_test_factory()
	_test_nav_chase()
	for f in files:
		_run_scenario(f)
	DmDb.reset()
	print("bosses: %d passed, %d failed" % [pass_n, fail_n])
	print("%s bosses %d checks%s" % ["PASS" if fail_n == 0 else "FAIL", pass_n + fail_n, "" if fail_n == 0 else " (%d failed)" % fail_n])
	quit(1 if fail_n > 0 else 0)


func ok(cond: bool, msg: String) -> void:
	if cond:
		pass_n += 1
	else:
		fail_n += 1
		printerr("FAIL: " + msg)


func _test_factory() -> void:
	var w := FakeWorld.new(1, "medium", 5)
	var all: Dictionary = Brains.make_all(w)
	ok(not all.is_empty() and all.size() == Brains.BOSS_IDS.size() and all.size() == DmContent.bosses().size(), "make_all builds a brain for each boss of the data (%d)" % all.size())
	for id in Brains.BOSS_IDS:
		ok(all.has(id) and all[id].id == id and not all[id].state["active"], "brain %s idle" % id)


func _apply(w, brain, o: Dictionary) -> void:
	match o["op"]:
		"awaken":
			brain.awaken(o["by"], o["empowered"])
		"damage":
			brain.damage(float(o["amount"]), o["by"], int(o["fracture"]))
		"stagger":
			brain.stagger(float(o["seconds"]))
		"resume":
			brain.resume()
		"set_players":
			w.player_list = []
			for p in o["players"]:
				w.player_list.append({"id": p["id"], "x": float(p["x"]), "z": float(p["z"]), "alive": p["alive"], "area": p["area"]})
		"kill_enemy":
			var e: Dictionary = w.enemy_get(int(o["id"]))
			if not e.is_empty():
				e["hp"] = 0.0
				e["state"] = "dead"
		"del_enemy":
			w.enemy_map.erase(int(o["id"]))
		"add_enemy":
			w.enemy_map[int(o["id"])] = {"id": int(o["id"]), "def": o["def"], "area": o["area"], "x": float(o["x"]), "z": float(o["z"]), "elite": false, "hp": float(o["hp"]), "max_hp": float(o["hp"]), "state": "idle"}
		"add_corpse":
			w.corpse_map[int(o["id"])] = {"id": int(o["id"]), "area": o["area"], "x": float(o["x"]), "z": float(o["z"])}
		"del_corpse":
			w.corpse_map.erase(int(o["id"]))
		"add_thrall":
			w.thrall_map[int(o["id"])] = {"id": int(o["id"]), "x": float(o["x"]), "z": float(o["z"]), "hp": float(o["hp"]), "max_hp": float(o["hp"]), "flash": 0.0, "state": "idle"}
		"set_boss":
			for k in o["fields"]:
				brain.state[k] = o["fields"][k]
		"set_cover":
			w.cover_boxes = o["boxes"].duplicate(true)
		_:
			ok(false, "unknown op " + str(o["op"]))


func _boss_snap(b) -> Dictionary:
	var s: Dictionary = b.state
	var out := {}
	for k in ["active", "x", "z", "facing", "hp", "maxHp", "phase", "state", "stateT", "flash", "fracture", "fractureT", "withered", "witheredT", "witheredDps", "level"]:
		out[k] = s[k]
	out["empowered"] = bool(s.get("empowered", false))
	return out


func _ents(m: Dictionary) -> Array:
	var out: Array = []
	for e in m.values():
		out.append({"id": e["id"], "hp": e["hp"], "maxHp": e["max_hp"], "state": e["state"], "x": e["x"], "z": e["z"]})
	out.sort_custom(func(a, b): return a["id"] < b["id"])
	return out


func _world_snap(w) -> Dictionary:
	var corpses: Array = w.corpse_map.keys()
	corpses.sort()
	var zones: Array = w.zone_map.keys()
	zones.sort()
	return {"enemies": _ents(w.enemy_map), "thralls": _ents(w.thrall_map), "corpses": corpses, "zones": zones}


func _run_scenario(file: String) -> void:
	# scenarios are committed gzip'd (tools/godot/trim-fixtures.py)
	var fx: Dictionary = JSON.parse_string(PackedByteArray(FileAccess.get_file_as_bytes(FX + file)).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8())
	var name: String = fx["name"]
	var w := FakeWorld.new(int(fx["seed"]) + 1, fx["difficulty"], int(fx["level"]))
	w.echoes_n = int(fx["echoes"])
	w.cover_boxes = fx["cover"].duplicate(true)
	var brain: RefCounted = Brains.make(w, fx["boss"])
	var expect_world: Dictionary = {}
	for tk in fx["ticks"]:
		w.log = []
		for o in tk["ops"]:
			_apply(w, brain, o)
		w.time += float(tk["dt"])
		w.expire_zones()
		brain.update(float(tk["dt"]))
		if tk.has("world"):
			expect_world = tk["world"]
		var msg := DeepDiff.diff(_boss_snap(brain), tk["boss"], "boss")
		if msg == "":
			msg = DeepDiff.diff(w.log, tk["log"], "log")
		if msg == "":
			msg = DeepDiff.diff(_world_snap(w), expect_world, "world")
		if msg == "":
			msg = DeepDiff.diff(w.time, tk["time"], "time")
		if msg != "":
			ok(false, "%s tick %d: %s" % [name, int(tk["t"]), msg])
			return
	ok(true, name)


## A world with a wall the boss cannot cross, on the live game's nav hooks: `walk` refuses a step into the wall, `detour` routes round its end.
class WallWorld extends FakeWorld:
	var last := Vector2(-18.0, -22.0)
	var routes := true
	var asked := 0
	func nav_active() -> bool:
		return true
	func walk(x: float, z: float) -> Vector2:
		if _wall(x, z):
			if not _wall(x, last.y):   # slide along the wall, like nav_clamp
				last = Vector2(x, last.y)
			elif not _wall(last.x, z):
				last = Vector2(last.x, z)
			return last
		last = Vector2(x, z)
		return last
	func _wall(x: float, z: float) -> bool:
		return absf(x + 14.0) < 0.4 and z < -17.0 and z > -27.0
	func detour(x0: float, z0: float, x1: float, z1: float) -> PackedVector2Array:
		asked += 1
		return PackedVector2Array([Vector2(x0, z0), Vector2(-15.0 if x0 < -14.0 else -13.0, -16.0), Vector2(-13.0, -16.0), Vector2(x1, z1)]) if routes else PackedVector2Array()


func _fresh(w: WallWorld, players: Array) -> RefCounted:
	w.player_list = players
	var brain: RefCounted = Brains.make(w, "gravedigger")
	brain.awaken("1", false)
	brain.state["x"] = -18.0
	brain.state["z"] = -22.0
	return brain


func _p(id: String, x: float, z: float) -> Dictionary:
	return {"id": id, "x": x, "z": z, "alive": true, "area": "graves"}


func _run_chase(w: WallWorld, brain: RefCounted, secs: float) -> Array:
	var switches := 0
	var last_t: Variant = null
	for i in int(secs / 0.1):
		w.time += 0.1
		brain.update(0.1)
		if brain._target_id != last_t:
			switches += 1
			last_t = brain._target_id
	return [switches, Vector2(float(brain.state["x"]), float(brain.state["z"]))]


func _test_nav_chase() -> void:
	# one hero behind a wall: the straight line is blocked; with a route the boss walks round and reaches it
	var w := WallWorld.new(7, "medium", 5)
	var brain := _fresh(w, [_p("a", -9.0, -22.0)])
	var r := _run_chase(w, brain, 30.0)
	ok((r[1] as Vector2).distance_to(Vector2(-9.0, -22.0)) < 4.5, "nav chase: the boss got round the wall to the hero (%s)" % str(r[1]))
	# control: the same fight with no route is the pinned boss the owner saw
	var w2 := WallWorld.new(7, "medium", 5)
	w2.routes = false
	var b2 := _fresh(w2, [_p("a", -9.0, -22.0)])
	var r2 := _run_chase(w2, b2, 30.0)
	ok(float((r2[1] as Vector2).x) < -13.0, "nav chase: (control) without a route the boss stays on its side (%s)" % str(r2[1]))
	# two heroes, one behind the wall with no route: the boss gives up on it and goes for the one it can reach
	var w3 := WallWorld.new(7, "medium", 5)
	w3.routes = false
	var b3 := _fresh(w3, [_p("far", -9.0, -22.0), _p("near", -22.0, -22.0)])
	var r3 := _run_chase(w3, b3, 30.0)
	ok((r3[1] as Vector2).distance_to(Vector2(-22.0, -22.0)) < 4.5 or float((r3[1] as Vector2).x) < -17.0, "nav chase: with a hero it cannot reach, it turns to the one it can (%s)" % str(r3[1]))
	# two heroes at nearly the same range do not make it swing between them
	var w4 := WallWorld.new(7, "medium", 5)
	var b4 := _fresh(w4, [_p("l", -18.0, -12.0), _p("r", -18.0, -31.8)])
	var r4 := _run_chase(w4, b4, 10.0)
	ok(int(r4[0]) <= 2, "nav chase: two heroes at similar range, the boss keeps one target (%d picks)" % int(r4[0]))
