extends RefCounted
## Replays one caster fixture (tools/godot/sim-cast.fixture.ts): the real AbilitySystem's casts, scripted by tick, against DmSimCaster + DmWorldSim,
## comparing each cast's result and, every checkpoint, the intents sent, the damage numbers, the player's state and the whole world.

var tol: float = 1e-9
var rel: float = 1e-12
var dump_dir: String = ""
var _snap = load("res://tests/sim/scenario_runner.gd").new()


func _const(v: float) -> float:
	return v


func _player_state(p: Dictionary, caster: DmSimCaster) -> Dictionary:
	var cds: Array = []
	var keys: Array = p["cooldowns"].keys()
	keys.sort()
	for k in keys:
		cds.append([k, p["cooldowns"][k]])
	return {
		"x": p["x"], "z": p["z"], "facing": p["facing"], "hp": p["hp"], "barrier": p["barrier"], "barrierPeak": p["barrierPeak"], "barrierHoldUntil": p["barrierHoldUntil"],
		"resource": p["resource"]["value"], "castUntil": p["castUntil"], "rootedUntil": p["rootedUntil"], "souls": float(p["souls"]), "unbreakableUntil": p["unbreakableUntil"],
		"bulwarkUntil": p["bulwarkUntil"], "bulwarkPerfectUntil": p["bulwarkPerfectUntil"], "veilForm": p["veilForm"], "betweenUntil": p["betweenUntil"],
		"area": p.get("area", ""), "alive": p["alive"], "cooldowns": cds, "wisps": float(caster.wisp_count()),
	}


func run(fx: Dictionary) -> Dictionary:
	var S: Dictionary = fx["setup"]
	var world: Dictionary = DmSimExact.load_json("res://data/sim/world.json")
	var nav := DmNav.new()
	for o in world["obstacles"]:
		nav.add_obstacle(DmNavObstacle.from_dict(o))
	for sb in world["sightBlockers"]:
		nav.add_sight_blocker(DmNavObstacle.from_dict(sb))
	var all: Array = []
	for a in DmContent.area_order():
		if a != "depths":
			all.append(a)
	nav.set_unlocked(all)
	var sim := DmWorldSim.new(nav, DmRng.new(int(S["seed"])))
	sim.waveTier = 2.0
	sim.set_crypts(world["crypts"])
	var p := DmPlayerRules.new_state(S["stats"], S["family"])
	p["loadout"] = S["loadout"]
	p["runes"] = S["runes"]
	p["hp"] = float(S["hp0"])
	p["area"] = S["area"]
	p["x"] = float(S["start"]["x"])
	p["z"] = float(S["start"]["z"])
	var caster := DmSimCaster.new(sim, p, "p1", S["discipline"], S["family"], S["mods"])
	var mr: float = S["mathRandom"]
	caster.random = Callable(self, "_const").bind(mr)
	caster.record_sent = true
	var dt := float(S["dt"])
	var cps: Array = fx["checkpoints"]
	var ci := 0
	var evs: Array = []
	var casts: Array = []
	var ok_cps := 0
	var msg := ""
	var script: Array = fx["script"]
	for tick in int(S["ticks"]):
		var st: Dictionary = script[tick]
		var now := float(tick + 1) * 50.0
		var sets: Dictionary = st["sets"]
		if sets.has("resource"):
			p["resource"]["value"] = float(sets["resource"])
		if sets.has("souls"):
			p["souls"] = float(sets["souls"])
		if sets.has("alive"):
			p["alive"] = bool(sets["alive"])
		if sets.has("hp"):
			p["hp"] = float(sets["hp"])
		var b: Dictionary = st["body"]
		p["x"] = float(b["x"])
		p["z"] = float(b["z"])
		p["area"] = b["area"] if b["area"] != null else ""
		p["alive"] = bool(b["alive"])
		caster.aim = st["aim"]
		sim.set_player(DmSimPlayer.make("p1", p["x"], p["z"], p["area"], p["alive"], float(b["level"]), String(b["family"])))
		if tick == 0:
			var al: Dictionary = S["ally"]
			sim.set_player(DmSimPlayer.make("p2", float(al["x"]), float(al["z"]), al["area"], true, float(al["level"])))
		for i in st["intents"]:
			sim.apply(i)
		for c: Dictionary in st["casts"]:
			var res := caster.cast(c["id"], c["target"], now)
			casts.append({"id": c["id"], "result": res})
			if res != c["result"] and msg == "":
				msg = "tick %d cast %s: got %s want %s" % [tick, c["id"], res, c["result"]]
		caster.update(now, dt)
		var events := sim.step(dt)
		for ev in events:
			caster.handle_event(ev)
			evs.append("%s|%s" % [ev["t"], ev["kind"] if ev.has("kind") else ""])
		if msg != "":
			break
		if (tick + 1) % int(S["every"]) == 0:
			var cp: Dictionary = cps[ci]
			ci += 1
			var got := {"world": _snap.snapshot(sim, evs), "player": _player_state(p, caster), "sent": caster.sent, "numbers": caster.popups, "notes": caster.notes, "casts": casts}
			evs = []
			casts = []
			caster.clear_log()
			caster.clear_popups()
			caster.notes = []
			var want := {"world": cp["world"], "player": cp["player"], "sent": cp["sent"], "numbers": cp["numbers"], "notes": cp["notes"], "casts": cp["casts"]}
			var d: String = _snap._diff(got, want, "", tol)
			if d == "":
				ok_cps += 1
			else:
				msg = "tick %d: %s" % [tick + 1, d]
				if dump_dir != "":
					var f := FileAccess.open(dump_dir + "/cast_%s_%d.json" % [fx["cast"], tick + 1], FileAccess.WRITE)
					f.store_string(JSON.stringify(got))
				break
	var total := cps.size()
	var messages: Array = []
	if msg != "":
		messages.append("FAIL cast_%s  %s" % [fx["cast"], msg.substr(0, 500)])
	return {"passed": ok_cps, "failed": total - ok_cps, "summary": "%d / %d checkpoints" % [ok_cps, total], "messages": messages}
