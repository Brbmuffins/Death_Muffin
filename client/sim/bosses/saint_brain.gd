class_name DmSaintBrain
extends "res://sim/bosses/boss_brain.gd"
## The Plague Saint: Rot Rain marks circles that become rot pools she heals in; censer swing up close; Plague Doctors feed her.
## Port of SaintBrain. (blessFx / linkFx are NOT reset on awaken, exactly like the TS fields.)

var _rain_cd := 4.0
var _swing_cd := 2.0
var _bless_fx := 0.0
var _link_fx := 0.0
var _s: Dictionary


func _init(world_: RefCounted) -> void:
	super(world_, "saint")
	_s = Content.get_export("bosses", "SAINT")


func _on_awaken() -> void:
	_rain_cd = 4.0
	_swing_cd = 2.0


func _on_phase(p: int) -> void:
	var spots: Array = []
	var wave: Array = ["plague_doctor", "plague_doctor", "flagellant"] if p == 2 else ["rat", "rat", "rat", "flagellant"]
	for i in wave.size():
		var at := _rim((float(i) / float(wave.size())) * PI * 2.0 + 0.4)
		spots.append(at)
		_spawn_add(wave[i], at[0], at[1])
	emit_boss("summon", state["x"], state["z"], {"phase": p, "targets": spots})


## Standing in her own rot?
func _in_rot() -> bool:
	for z in world.hostile_toxic_zones():
		if Geom.hyp(z["x"] - float(state["x"]), z["z"] - float(state["z"])) <= float(z["r"]) + 0.6:
			return true
	return false


## Plague Doctors standing in her arena (the summoned ones and any that wandered in).
func _linked_doctors() -> Array:
	var out: Array = []
	for e in world.enemies():
		if e["def"] != "plague_doctor" or float(e["hp"]) <= 0.0 or e["area"] != def["area"]:
			continue
		if Geom.hyp(e["x"] - _ax(), e["z"] - _az()) <= _ar() + 2.0:
			out.append([e["x"], e["z"]])
	return out


func _tick(dt: float, _players: Array) -> void:
	var s := state
	# Doctors' link: every doctor in the arena feeds her, and the view draws a beam from each.
	var docs := _linked_doctors()
	if not docs.is_empty():
		s["hp"] = minf(float(s["maxHp"]), float(s["hp"]) + float(s["maxHp"]) * float(_s["doctors"]["healPerS"]) * float(docs.size()) * dt)
		_link_fx -= dt
		if _link_fx <= 0.0:
			_link_fx = float(_s["doctors"]["beatS"])
			emit_boss("link", s["x"], s["z"], {"targets": docs, "ms": 0})
	if not _in_rot():
		return
	# Pestilent Blessing: the rot feeds her.
	s["hp"] = minf(float(s["maxHp"]), float(s["hp"]) + float(s["maxHp"]) * float(_s["blessing"]["healPerS"]) * dt)
	_bless_fx -= dt
	if _bless_fx <= 0.0:
		_bless_fx = 0.8
		emit_boss("blessed", s["x"], s["z"])


func _resolve(p, players: Array) -> void:
	var S := _s
	var s := state
	if p.kind == "rotRain":
		super._resolve(p, players)
		for t in (p.targets if p.targets != null else []):
			world.add_hostile_pool(t[0], t[1], float(S["rain"]["r"]), _dmg(float(S["rain"]["dmg"])) * float(S["rain"]["poolDpsMult"]), float(S["rain"]["poolSP3"]) if int(s["phase"]) == 3 else float(S["rain"]["poolS"]))
		return
	if p.kind == "swing":
		var sr: float = float(S["swing"]["r"])
		var sh: float = float(S["swing"]["halfDeg"]) * PI / 180.0
		_strike_players(players, func(pl): return Geom.hyp(pl["x"] - p.x, pl["z"] - p.z) <= sr + 0.3 and Geom.angle_diff(Geom.angle_to(p.x, p.z, pl["x"], pl["z"]), p.dir) <= sh, float(S["swing"]["dmg"]), p.x, p.z)
		_hurt_thralls(func(t): return Geom.hyp(t["x"] - p.x, t["z"] - p.z) <= sr and Geom.angle_diff(Geom.angle_to(p.x, p.z, t["x"], t["z"]), p.dir) <= sh)
		emit_boss("swing", p.x, p.z, {"r": p.r, "ms": 0, "dir": p.dir})
		return
	super._resolve(p, players)


func _circle_damage(_kind: String) -> float:
	return float(_s["rain"]["dmg"])


func _think(dt: float, players: Array) -> void:
	var S := _s
	var s := state
	var ph: int = s["phase"]
	var fast := 0.75 if ph == 3 else (0.88 if ph == 2 else 1.0)
	_rain_cd -= dt
	_swing_cd -= dt
	var nn := _nearest(players)
	var nearest: Dictionary = nn["nearest"]
	var nd: float = nn["nd"]
	if not _busy():
		if _rain_cd <= 0.0:
			_rain_cd = float(S["rain"]["cd"]) * fast
			var lo := int(S["rain"]["circles"][0])
			var hi := int(S["rain"]["circles"][1])
			var n := lo + int(floor(world.rand() * float(hi - lo + 1))) + (2 if ph == 3 else 0)
			var targets: Array = []
			for pl in players:
				targets.append([pl["x"], pl["z"]])
			while targets.size() < n:
				var a: float = world.rand() * PI * 2.0
				var r: float = 2.0 + world.rand() * (_ar() - 3.0)
				targets.append([_ax() + sin(a) * r, _az() + cos(a) * r])
			_telegraph("rotRain", s["x"], s["z"], float(S["rain"]["r"]), float(S["rain"]["windupMs"]), {"targets": targets})
		elif _swing_cd <= 0.0 and nd < float(S["swing"]["r"]) + 0.5:
			_swing_cd = float(S["swing"]["cd"]) * fast
			_telegraph("swing", s["x"], s["z"], float(S["swing"]["r"]), float(S["swing"]["windupMs"]), {"dir": Geom.angle_to(s["x"], s["z"], nearest["x"], nearest["z"])})
	_chase(nearest, nd, (2.1 if ph == 3 else (1.8 if ph == 2 else 1.5)) * (0.3 if _busy() else 1.0), dt, 2.0, 2.8)
