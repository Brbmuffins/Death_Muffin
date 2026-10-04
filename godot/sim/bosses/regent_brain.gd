class_name DmRegentBrain
extends "res://sim/bosses/boss_brain.gd"
## The Cinder Regent: Coals (burning circles), Cinder Cleave (firebreak down its line), Conflagration (whole arena burns except a few
## ash circles). Port of RegentBrain.

var _coals_cd := 3.0
var _cleave_cd := 2.0
var _confl_cd := 9.0
var _r: Dictionary


func _init(world_: RefCounted) -> void:
	super(world_, "regent")
	_r = Content.get_export("bosses", "REGENT")


func _on_awaken() -> void:
	_coals_cd = 3.0
	_cleave_cd = 2.0
	_confl_cd = 9.0


func _on_phase(p: int) -> void:
	var wave: Array = _r["adds"]["p2"] if p == 2 else (_r["adds"]["p3"] if p == 3 else [])
	var spots: Array = []
	for i in wave.size():
		var at := _rim((float(i) / float(wave.size())) * PI * 2.0 + 0.5)
		spots.append(at)
		_spawn_add(wave[i], at[0], at[1])
	if not spots.is_empty():
		emit_boss("summon", state["x"], state["z"], {"phase": p, "targets": spots})


func _circle_damage(kind: String) -> float:
	return float(_r["coals"]["dmg"]) if kind == "coals" else 20.0


## Ash circles for a Conflagration: spread over the arena, never on top of one another.
func _ash_spots(players: Array) -> Array:
	var C: Dictionary = _r["conflagration"]
	var extra := int(floor(float(maxi(0, players.size() - 1)) / 3.0))
	var n := int(C["safe"][int(state["phase"]) - 1]) + extra
	var spots: Array = []
	var tries := 0
	while spots.size() < n and tries < 80:
		var a: float = world.rand() * PI * 2.0
		var r: float = sqrt(world.rand()) * (_ar() - float(C["safeR"]) - 0.6)
		var x := _ax() + sin(a) * r
		var z := _az() + cos(a) * r
		var ok := true
		for sp in spots:
			if not (Geom.hyp(sp[0] - x, sp[1] - z) > float(C["safeR"]) * 2.0 + 1.0):
				ok = false
				break
		if ok:
			spots.append([x, z])
		tries += 1
	return spots


func _resolve(p, players: Array) -> void:
	var R := _r
	var s := state
	if p.kind == "coals":
		super._resolve(p, players)
		for t in (p.targets if p.targets != null else []):
			world.ember_pool(t[0], t[1], float(R["coals"]["r"]), float(R["coals"]["poolS"]), _dmg(float(R["coals"]["dmg"])) * float(R["coals"]["poolDpsMult"]))
		return
	if p.kind == "cleave":
		var cr: float = float(R["cleave"]["r"])
		var ch: float = float(R["cleave"]["halfDeg"]) * PI / 180.0
		var in_cone := func(x: float, z: float) -> bool:
			return Geom.hyp(x - p.x, z - p.z) <= cr + 0.3 and Geom.angle_diff(Geom.angle_to(p.x, p.z, x, z), p.dir) <= ch
		_strike_players(players, func(pl): return in_cone.call(pl["x"], pl["z"]), float(R["cleave"]["dmg"]), p.x, p.z)
		_hurt_thralls(func(t): return in_cone.call(t["x"], t["z"]))
		# The firebreak: burning ground down the line of the blow.
		for d in R["cleave"]["trail"]:
			world.ember_pool(p.x + sin(float(p.dir)) * float(d), p.z + cos(float(p.dir)) * float(d), float(R["cleave"]["trailR"]), float(R["cleave"]["trailS"]), _dmg(float(R["cleave"]["dmg"])) * float(R["cleave"]["trailDpsMult"]))
		emit_boss("cleave", p.x, p.z, {"r": p.r, "ms": 0, "dir": p.dir})
		return
	if p.kind == "conflagration":
		var C: Dictionary = R["conflagration"]
		var safe: Array = p.targets if p.targets != null else []
		var safe_r: float = float(C["safeR"])
		var on_ash := func(x: float, z: float) -> bool:
			for sp in safe:
				if Geom.hyp(x - sp[0], z - sp[1]) <= safe_r:
					return true
			return false
		var in_arena := func(x: float, z: float) -> bool:
			return Geom.hyp(x - _ax(), z - _az()) <= _ar() + 0.5
		for pl in players:
			if in_arena.call(pl["x"], pl["z"]) and not on_ash.call(pl["x"], pl["z"]):
				world.emit({"t": "hurt", "player": pl["id"], "dmg": _dmg(float(C["dmg"])), "from": "ember", "x": _ax(), "z": _az()})
		_hurt_thralls(func(t): return in_arena.call(t["x"], t["z"]) and not on_ash.call(t["x"], t["z"]), float(C["dmg"]) * 0.5)
		# What is left of the floor smoulders in a few places (never on the ash).
		for i in int(C["embers"]):
			var a: float = world.rand() * PI * 2.0
			var r: float = sqrt(world.rand()) * (_ar() - 2.0)
			var x := _ax() + sin(a) * r
			var z := _az() + cos(a) * r
			if not on_ash.call(x, z):
				world.ember_pool(x, z, 1.8, float(C["emberS"]), _dmg(float(R["coals"]["dmg"])) * float(R["coals"]["poolDpsMult"]))
		emit_boss("conflagration", _ax(), _az(), {"targets": safe, "r": _ar(), "ms": 0})
		return
	super._resolve(p, players)


func _think(dt: float, players: Array) -> void:
	var R := _r
	var s := state
	var ph: int = s["phase"]
	var fast := 0.75 if ph == 3 else (0.88 if ph == 2 else 1.0)
	_coals_cd -= dt
	_cleave_cd -= dt
	_confl_cd -= dt
	var nn := _nearest(players)
	var nearest: Dictionary = nn["nearest"]
	var nd: float = nn["nd"]
	if not _busy():
		if _confl_cd <= 0.0:
			_confl_cd = float(R["conflagration"]["cd"]) * fast
			_telegraph("conflagration", _ax(), _az(), _ar(), float(R["conflagration"]["windupMs"]), {"targets": _ash_spots(players)})
		elif _coals_cd <= 0.0:
			_coals_cd = float(R["coals"]["cd"]) * fast
			var lo := int(R["coals"]["circles"][0])
			var hi := int(R["coals"]["circles"][1])
			var n := lo + int(floor(world.rand() * float(hi - lo + 1))) + (2 if ph == 3 else 0)
			var targets: Array = []
			for pl in players:
				targets.append([pl["x"], pl["z"]])
			while targets.size() < n:
				var a: float = world.rand() * PI * 2.0
				var r: float = 2.0 + world.rand() * (_ar() - 3.0)
				targets.append([_ax() + sin(a) * r, _az() + cos(a) * r])
			_telegraph("coals", s["x"], s["z"], float(R["coals"]["r"]), float(R["coals"]["windupMs"]), {"targets": targets})
		elif _cleave_cd <= 0.0 and nd < float(R["cleave"]["r"]) + 0.5:
			_cleave_cd = float(R["cleave"]["cd"]) * fast
			_telegraph("cleave", s["x"], s["z"], float(R["cleave"]["r"]), float(R["cleave"]["windupMs"]), {"dir": Geom.angle_to(s["x"], s["z"], nearest["x"], nearest["z"])})
	_chase(nearest, nd, (2.2 if ph == 3 else (1.9 if ph == 2 else 1.6)) * (0.3 if _busy() else 1.0), dt, 2.0, 2.8)
