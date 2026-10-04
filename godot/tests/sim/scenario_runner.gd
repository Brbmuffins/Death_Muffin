extends RefCounted
## Replays one whole-sim scenario fixture (tools/godot/fixtures-sim-run.ts) against DmWorldSim and compares the canonical snapshots.
## The field lists below mirror ENEMY_F / THRALL_F / CORPSE_F / ZONE_F of the generator (name, kind): n number, s string, b bool, id int (-1 = none),
## v variant (undefined -> null), m number with undefined/Infinity -> -1, e number with undefined -> -1.

const ENEMY_F := [["id", "n"], ["def", "s"], ["area", "s"], ["level", "n"], ["elite", "b"], ["x", "n"], ["z", "n"], ["facing", "n"], ["hp", "n"], ["maxHp", "n"], ["damage", "n"], ["speed", "n"], ["radius", "n"], ["scale", "n"], ["state", "s"], ["stateT", "n"], ["attackCd", "n"], ["targetPlayer", "s"], ["targetThrall", "id"], ["aimX", "n"], ["aimZ", "n"], ["channelCorpse", "id"], ["flankSide", "n"], ["fracture", "n"], ["fractureT", "n"], ["withered", "n"], ["witheredT", "n"], ["witheredDps", "n"], ["witheredOwner", "s"], ["contagious", "b"], ["slowT", "n"], ["wardSlowT", "n"], ["lastHitBy", "s"], ["flash", "n"], ["gait", "n"], ["moving", "b"], ["bleedT", "n"], ["bleedDps", "n"], ["bleedOwner", "s"], ["chillT", "n"], ["sanctT", "n"], ["hexT", "n"], ["silenceT", "n"], ["stunT", "n"], ["rootT", "n"], ["incenseT", "n"], ["knellBeats", "n"], ["knellNext", "n"], ["knellOwner", "s"], ["knellDamage", "n"], ["hexOwner", "s"], ["diving", "b"], ["diveX", "n"], ["diveZ", "n"], ["groundT", "n"], ["hooking", "b"], ["hookCd", "n"], ["fleeT", "n"], ["erupting", "v"], ["dugIn", "b"], ["digPending", "b"], ["burrowLeft", "v"], ["unbindCd", "n"], ["unboundBy", "id"], ["blockFxAt", "n"], ["auraCd", "n"], ["affix", "s"], ["affixCd", "v"], ["tollAt", "v"], ["markT", "n"], ["markBonus", "n"], ["markBy", "s"], ["plagueAt", "n"], ["extra", "v"]]
const THRALL_F := [["id", "n"], ["owner", "s"], ["kind", "s"], ["x", "n"], ["z", "n"], ["facing", "n"], ["hp", "n"], ["maxHp", "n"], ["damage", "n"], ["attackInterval", "n"], ["range", "n"], ["speed", "n"], ["state", "s"], ["stateT", "n"], ["attackCd", "n"], ["target", "id"], ["slot", "n"], ["bornAt", "n"], ["empowered", "b"], ["flash", "n"], ["gait", "n"], ["moving", "b"], ["rallyT", "n"], ["champion", "b"], ["echoUntil", "e"], ["allyHeal", "n"], ["cursedT", "n"], ["stallT", "n"], ["nextPathAt", "n"], ["detourUntil", "n"], ["seatX", "v"], ["seatZ", "v"]]
const CORPSE_F := [["id", "n"], ["x", "n"], ["z", "n"], ["kind", "s"], ["enemy", "s"], ["elite", "b"], ["facing", "n"], ["scale", "n"], ["area", "s"], ["bornAt", "n"], ["expiresAt", "n"], ["ruptureAt", "m"], ["seedOwner", "s"], ["seedDmg", "n"], ["seedCap", "n"], ["seedArmedAt", "m"], ["seedExpires", "n"], ["echoOwner", "s"]]
const ZONE_F := [["id", "n"], ["kind", "s"], ["owner", "s"], ["x", "n"], ["z", "n"], ["r", "n"], ["until", "n"], ["bornAt", "n"], ["tick", "n"], ["dps", "n"], ["slow", "n"], ["witheredCap", "n"], ["bloom", "b"], ["hostile", "b"], ["creep", "n"], ["contagion", "b"], ["gen", "m"], ["spreadT", "m"]]

var tol: float = 1e-6
## Set by the caller (env/args) to dump the Godot snapshot of the first failing checkpoint.
var dump_dir: String = ""


func _norm(v: Variant, k: String) -> Variant:
	match k:
		"n":
			return float(v) if (v is float or v is int) else 0.0
		"s":
			return v if v is String else ""
		"b":
			return bool(v) if v != null else false
		"id", "e":
			return float(v) if (v is float or v is int) else -1.0
		"m":
			if (v is float or v is int) and is_finite(float(v)):
				return float(v)
			return -1.0
		_:
			if v is float and is_nan(v):
				return null
			return v


func _fields(o: Object, spec: Array) -> Dictionary:
	var out := {}
	for f: Array in spec:
		out[f[0]] = _norm(o.get(f[0]), f[1])
	return out


func _ev_key(ev: Dictionary) -> String:
	var id: Variant = ev.get("id")
	if id == null and ev.has("corpse"):
		id = ev["corpse"].id
	if id == null and ev.has("zone"):
		id = ev["zone"].id
	if id == null:
		id = ev.get("corpseId")
	return "%s|%s|%s|%s|%s|%s" % [ev["t"], _s(ev.get("kind")), _s(ev.get("reason")), _s(ev.get("from")), _s(id), _s(ev.get("player"))]


func _s(v: Variant) -> String:
	if v == null:
		return ""
	if v is float and v == floorf(v) and absf(v) < 1e15:
		return str(int(v))
	return str(v)


func _sorted_by_id(a: Array) -> Array:
	var out := a.duplicate()
	out.sort_custom(func(x, y): return x.id < y.id)
	return out


func _sorted_pairs(d: Dictionary) -> Array:
	var keys := d.keys()
	keys.sort()
	var out: Array = []
	for k in keys:
		out.append([k, d[k]])
	return out


func snapshot(sim: DmWorldSim, evs: Array) -> Dictionary:
	var run: Variant = sim.depths
	var enemies: Array = []
	for e in _sorted_by_id(sim.enemies.values()):
		enemies.append(_fields(e, ENEMY_F))
	var thr: Array = []
	for t in _sorted_by_id(sim.thralls.values()):
		var d := _fields(t, THRALL_F)
		d["detourN"] = float(t.detour.size())
		thr.append(d)
	var corpses: Array = []
	for c in _sorted_by_id(sim.corpses.values()):
		corpses.append(_fields(c, CORPSE_F))
	var zones: Array = []
	for z in _sorted_by_id(sim.zones.values()):
		zones.append(_fields(z, ZONE_F))
	var walls: Array = []
	for w: Dictionary in _sorted_by_id_d(sim.walls.values()):
		walls.append({"id": w["id"], "owner": w["owner"], "x0": w["x0"], "z0": w["z0"], "x1": w["x1"], "z1": w["z1"], "until": w["until"]})
	var brands: Array = []
	for id in sim.brands:
		var b: Dictionary = sim.brands[id]
		brands.append({"id": id, "owner": b["owner"], "x": b["x"], "z": b["z"], "area": b["area"], "until": b["until"]})
	var nodes: Array = []
	for n: Dictionary in sim.nodes.values():
		nodes.append([n["id"], n["remaining"], n["respawnAt"]])
	return {
		"time": sim.time, "nextId": sim._next_id, "rngCalls": sim.rng_calls, "surgeIn": sim.surgeIn,
		"enemies": enemies, "thralls": thr, "corpses": corpses, "zones": zones, "walls": walls, "brands": brands,
		"surge": ({"area": sim.surge["area"], "x": sim.surge["x"], "z": sim.surge["z"], "wavesSpawned": sim.surge["wavesSpawned"], "spawned": sim.surge["spawned"], "killed": sim.surge["killed"], "ids": sim.surge["ids"].size()} if sim.surge != null else null),
		"waveTimers": _sorted_pairs(sim.waveTimers), "waveCounts": _sorted_pairs(sim.waveCounts), "vacantS": _sorted_pairs(sim.vacantS), "arrivedAt": _sorted_pairs(sim.arrivedAt),
		"nodes": nodes,
		"depths": ({"depth": run["depth"], "need": run["need"], "kills": run["kills"], "stairOpen": run["stairOpen"], "floorT": run["floorT"], "waveT": run["waveT"], "waved": run["waved"], "peak": run["peak"], "floors": run["floors"], "totalKills": run["totalKills"]} if run != null else null),
		"raised": _sorted_pairs(sim.raised),
		"players": _players(sim),
		"bossActive": sim.boss.state.active,
		"events": evs,
	}


func _players(sim: DmWorldSim) -> Array:
	var out: Array = []
	for p: DmSimPlayer in sim.players.values():
		out.append([p.id, p.x, p.z, p.alive, p.area])
	return out


func _sorted_by_id_d(a: Array) -> Array:
	var out := a.duplicate()
	out.sort_custom(func(x, y): return x["id"] < y["id"])
	return out


func _world() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/world.json"))


func _body(b: Dictionary) -> DmSimPlayer:
	var area: String = b["area"] if b["area"] != null else ""
	return DmSimPlayer.make(b["id"], float(b["x"]), float(b["z"]), area, bool(b["alive"]), float(b.get("level", 0.0)), b.get("family", ""))


func _call(sim: DmWorldSim, nav: DmNav, c: Dictionary) -> void:
	var a: Array = c["a"]
	match c["m"]:
		"startDepths":
			sim.start_depths(a[0], int(a[1]), int(a[2]), bool(a[3]))
		"descendDepths":
			sim.descend_depths()
		"endDepths":
			sim.end_depths()
		"spawnEnemy":
			sim.spawn_enemy(a[0], a[1], float(a[2]), float(a[3]), bool(a[4]), bool(a[5]), a[6] if (a.size() > 6 and a[6] != null) else "")
		"startSurge":
			sim.start_surge(a[0])
		"clearArea":
			sim.clear_area(a[0])
		"markVisited":
			sim.mark_visited(a[0])
		"removePlayer":
			sim.remove_player(a[0])
		"retagPlayer":
			sim.retag_player(a[0], a[1])
		"setUnlocked":
			nav.set_unlocked(a[0])
		"setWaveTier":
			sim.waveTier = float(a[0])
		_:
			push_error("unknown call " + str(c["m"]))


func run(fx: Dictionary) -> Dictionary:
	var S: Dictionary = fx["setup"]
	var world := _world()
	var nav := DmNav.new()
	if S["nav"] == "world":
		for o in world["obstacles"]:
			nav.add_obstacle(DmNavObstacle.from_dict(o))
		for s in world["sightBlockers"]:
			nav.add_sight_blocker(DmNavObstacle.from_dict(s))
	if S["unlocked"] != null:
		nav.set_unlocked(S["unlocked"])
	var sim := DmWorldSim.new(nav, DmRng.new(int(S["seed"])))
	sim.difficulty = S["difficulty"]
	sim.waveTier = float(S["waveTier"])
	if S["omen"] != null:
		sim.omen = DmContent.file("omens")["OMENS"][S["omen"]]
	sim.vows = S["vows"]
	sim.corpseLifeMult = float(S["corpseLifeMult"])
	if S["crypts"]:
		sim.set_crypts(world["crypts"])
	if S["cover"]:
		sim.set_cover(world["cover"])
	if S["nodes"]:
		sim.set_nodes(world["nodes"])
	var dt := float(S["dt"])
	var every := int(S["every"])
	var script: Array = fx["script"]
	var si := 0
	var cps: Array = fx["checkpoints"]
	var ci := 0
	var window: Array = []
	var ok_cps := 0
	var msg := ""
	var fail_tick := -1
	for tick in int(S["ticks"]):
		while si < script.size() and int(script[si]["tick"]) == tick:
			var st: Dictionary = script[si]
			si += 1
			for b in st.get("players", []):
				sim.set_player(_body(b))
			for c in st.get("calls", []):
				_call(sim, nav, c)
			for i in st.get("intents", []):
				sim.apply(i)
		var evs := sim.step(dt)
		for ev in evs:
			window.append(_ev_key(ev))
		if ci < cps.size() and int(cps[ci]["tick"]) == tick + 1:
			var want: Dictionary = cps[ci]["snap"]
			ci += 1
			var got := snapshot(sim, window)
			window = []
			var d := _diff(got, want, "", tol)
			if d == "":
				ok_cps += 1
			elif msg == "":
				msg = "tick %d: %s" % [tick + 1, d]
				fail_tick = tick + 1
				if dump_dir != "":
					var f := FileAccess.open(dump_dir + "/%s_%d.json" % [fx["scenario"], tick + 1], FileAccess.WRITE)
					f.store_string(JSON.stringify(got))
			if msg != "":
				break
		elif ci >= cps.size():
			break
	var total := cps.size()
	var summary := "%d / %d checkpoints" % [ok_cps, total]
	var messages: Array = []
	if msg != "":
		messages.append("FAIL scn_%s  %s" % [fx["scenario"], msg.substr(0, 400)])
	return {"passed": ok_cps, "failed": total - ok_cps, "summary": summary, "messages": messages}


func _diff(a: Variant, b: Variant, path: String, t: float) -> String:
	if (a is int or a is float) and (b is int or b is float):
		var x := float(a)
		var y := float(b)
		if is_nan(x) and is_nan(y):
			return ""
		var d := absf(x - y)
		return "" if (d <= t or d <= 1e-9 * maxf(absf(x), absf(y))) else "%s: got %s want %s" % [path, a, b]
	if a is Array and b is Array:
		if a.size() != b.size():
			# events: show the first differing entry rather than the size
			if path.ends_with(".events"):
				for i in mini(a.size(), b.size()):
					if a[i] != b[i]:
						return "%s[%d]: got %s want %s (sizes %d/%d)" % [path, i, a[i], b[i], a.size(), b.size()]
			return "%s: array size got %d want %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := _diff(a[i], b[i], "%s[%d]" % [path, i], t)
			if d != "":
				return d
		return ""
	if a is Dictionary and b is Dictionary:
		for k in b:
			if not a.has(k):
				return "%s.%s: missing in got" % [path, k]
			var d := _diff(a[k], b[k], "%s.%s" % [path, k], t)
			if d != "":
				return d
		for k in a:
			if not b.has(k):
				return "%s.%s: unexpected in got" % [path, k]
		return ""
	if a == null and b == null:
		return ""
	return "" if (typeof(a) == typeof(b) and a == b) else "%s: got %s want %s" % [path, a, b]
