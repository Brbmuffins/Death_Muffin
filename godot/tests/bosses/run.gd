extends SceneTree
## Headless: godot --headless --path godot --script res://tests/bosses/run.gd
## Replays every scenario in tests/bosses/fixtures (*.json.gz, captured from the real TS BossBrain; committed answer keys) through the
## GDScript brains and compares, per tick: the boss state, the ordered world-call log (events, spawns, pools, removals) and the
## entities left in the world. First mismatch per scenario is reported.

const FX := "res://tests/bosses/fixtures/"
const Brains := preload("res://sim/bosses/boss_brains.gd")
const FakeWorld := preload("res://tests/bosses/fake_world.gd")
const DeepDiff := preload("res://tests/bosses/deep_diff.gd")

var pass_n := 0
var fail_n := 0


func _init() -> void:
	var dir := DirAccess.open(FX)
	var files: Array = []
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".json.gz"):
				files.append(f)
	if files.is_empty():
		printerr("fixtures missing: fixtures are committed: tests/bosses/fixtures/*.json.gz")
		print("bosses: 0 passed, 1 failed")
		quit(1)
		return
	files.sort()
	_test_factory()
	for f in files:
		_run_scenario(f)
	print("bosses: %d passed, %d failed" % [pass_n, fail_n])
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
	ok(all.size() == 7, "make_all builds 7 brains")
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
