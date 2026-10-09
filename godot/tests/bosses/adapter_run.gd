extends SceneTree
## Headless: godot --headless --path godot --script res://tests/bosses/adapter_run.gd
## Runs the golden fixtures through DmBossFactory -> DmBossAdapter -> DmSimBossWorld -> a mock sim (sim entity classes), i.e. the
## exact path the sim uses. Needs the sim track's entity classes + boss_controller (skipped with a notice when absent).

const FX := "res://tests/bosses/fixtures/"
const DeepDiff := preload("res://tests/bosses/deep_diff.gd")

var pass_n := 0
var fail_n := 0


func _init() -> void:
	if not FileAccess.file_exists("res://sim/boss_controller.gd"):
		print("adapter: skipped (res://sim/boss_controller.gd not present; merge the sim track first)")
		quit(0)
		return
	var dir := DirAccess.open(FX)
	var files: Array = []
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".json.gz"):
				files.append(f)
	if files.is_empty():
		printerr("fixtures missing: fixtures are committed: tests/bosses/fixtures/*.json.gz")
		print("adapter: 0 passed, 1 failed")
		quit(1)
		return
	files.sort()
	for f in files:
		_run(f)
	print("adapter: %d passed, %d failed" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)


func ok(cond: bool, msg: String) -> void:
	if cond:
		pass_n += 1
	else:
		fail_n += 1
		printerr("FAIL: " + msg)


func _snap(c) -> Dictionary:
	var s = c.state
	return {"active": s.active, "x": s.x, "z": s.z, "facing": s.facing, "hp": s.hp, "maxHp": s.maxHp, "phase": s.phase, "state": s.state, "stateT": s.stateT, "flash": s.flash, "fracture": s.fracture, "fractureT": s.fractureT, "withered": s.withered, "witheredT": s.witheredT, "witheredDps": s.witheredDps, "level": s.level, "empowered": s.empowered}


func _apply(sim, c, o: Dictionary) -> void:
	var Player := load("res://sim/sim_player.gd")
	var Thrall := load("res://sim/sim_thrall.gd")
	var Corpse := load("res://sim/sim_corpse.gd")
	var Enemy := load("res://sim/sim_enemy.gd")
	match o["op"]:
		"awaken":
			c.awaken(o["by"], o["empowered"])
		"damage":
			c.damage(float(o["amount"]), o["by"], float(o["fracture"]))
		"stagger":
			c.stagger(float(o["seconds"]))
		"resume":
			c.resume()
		"set_players":
			sim.players = {}
			for p in o["players"]:
				var sp = Player.new()
				sp.id = p["id"]
				sp.x = float(p["x"])
				sp.z = float(p["z"])
				sp.alive = p["alive"]
				sp.area = p["area"]
				sim.players[sp.id] = sp
		"kill_enemy":
			var e = sim.enemies.get(int(o["id"]))
			if e != null:
				e.hp = 0.0
				e.state = "dead"
		"del_enemy":
			sim.enemies.erase(int(o["id"]))
		"add_enemy":
			var ne = Enemy.new()
			ne.id = int(o["id"])
			ne.def = o["def"]
			ne.area = o["area"]
			ne.x = float(o["x"])
			ne.z = float(o["z"])
			ne.hp = float(o["hp"])
			ne.maxHp = float(o["hp"])
			ne.state = "idle"
			sim.enemies[ne.id] = ne
		"add_corpse":
			var nc = Corpse.new()
			nc.id = int(o["id"])
			nc.area = o["area"]
			nc.x = float(o["x"])
			nc.z = float(o["z"])
			sim.corpses[nc.id] = nc
		"del_corpse":
			sim.corpses.erase(int(o["id"]))
		"add_thrall":
			var nt = Thrall.new()
			nt.id = int(o["id"])
			nt.x = float(o["x"])
			nt.z = float(o["z"])
			nt.hp = float(o["hp"])
			nt.maxHp = float(o["hp"])
			sim.thralls[nt.id] = nt
		"set_boss":
			for k in o["fields"]:
				c.state.set(k, o["fields"][k])
		"set_cover":
			sim.cover = o["boxes"].duplicate(true)


func _run(file: String) -> void:
	# scenarios are committed gzip'd (tools/godot/trim-fixtures.py)
	var fx: Dictionary = JSON.parse_string(PackedByteArray(FileAccess.get_file_as_bytes(FX + file)).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8())
	var name: String = fx["name"]
	var Factory := load("res://sim/bosses/boss_factory.gd")
	var Mock := load("res://tests/bosses/mock_sim.gd")
	var sim = Mock.new(int(fx["seed"]) + 1, fx["difficulty"], int(fx["level"]))
	sim.vowFx = {"echoes": int(fx["echoes"])}
	sim.cover = fx["cover"].duplicate(true)
	var c = Factory.make_all(sim)[fx["boss"]]
	for tk in fx["ticks"]:
		sim.log = []
		for o in tk["ops"]:
			_apply(sim, c, o)
		sim.time += float(tk["dt"])
		sim.expire_zones()
		c.update(float(tk["dt"]))
		var msg := DeepDiff.diff(_snap(c), tk["boss"], "boss")
		if msg == "":
			msg = DeepDiff.diff(sim.log, tk["log"], "log")
		if msg != "":
			ok(false, "%s tick %d: %s" % [name, int(tk["t"]), msg])
			return
	ok(true, name)
