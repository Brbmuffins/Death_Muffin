class_name DmCongregationBrain
extends "res://sim/bosses/boss_brain.gd"
## The Drowned Congregation: Flood Hymn (a 120 degree arc, pews are cover), Drowning Grasp rings, a maul up close; each phase the
## congregation climbs out. Port of CongregationBrain.

var _hymn_cd := 6.0
var _grasp_cd := 3.0
var _melee_cd := 2.0
var _c: Dictionary


func _init(world_: RefCounted) -> void:
	super(world_, "congregation")
	_c = Content.get_export("bosses", "CONGREGATION")


func _on_awaken() -> void:
	_hymn_cd = 6.0
	_grasp_cd = 3.0
	_melee_cd = 2.0


func _on_phase(p: int) -> void:
	var spots: Array = []
	for i in 6:
		var at := _rim((float(i) / 6.0) * PI * 2.0 + 0.3)
		spots.append(at)
		_spawn_add("wraith" if i < 4 else "penitent", at[0], at[1])
	emit_boss("summon", state["x"], state["z"], {"phase": p, "targets": spots})


## Is the player sheltered from her by a pew?
func covered(px: float, pz: float, from_x: float = NAN, from_z: float = NAN) -> bool:
	var fx: float = float(state["x"]) if is_nan(from_x) else from_x
	var fz: float = float(state["z"]) if is_nan(from_z) else from_z
	for b in world.cover():
		if Geom.segment_hits_box(fx, fz, px, pz, b):
			return true
	return false


func _resolve(p, players: Array) -> void:
	var C := _c
	var s := state
	if p.kind == "hymn":
		var reach: float = float(C["hymn"]["reach"])
		var half: float = float(C["hymn"]["halfDeg"]) * PI / 180.0
		var in_arc := func(x: float, z: float) -> bool:
			return Geom.hyp(x - p.x, z - p.z) <= reach and Geom.angle_diff(Geom.angle_to(p.x, p.z, x, z), p.dir) <= half
		for pl in players:
			if not in_arc.call(pl["x"], pl["z"]) or covered(pl["x"], pl["z"], p.x, p.z):
				continue
			var soaked: bool = int(s["phase"]) == 3 and Geom.hyp(pl["x"] - _ax(), pl["z"] - _az()) > float(C["water"]["dais"])
			world.emit({"t": "hurt", "player": pl["id"], "dmg": _dmg(float(C["hymn"]["base"]) * float(C["hymn"]["dmgMult"]) * (float(C["hymn"]["soakedMult"]) if soaked else 1.0)), "from": "boss", "x": p.x, "z": p.z, "chillMs": 2000})
		_hurt_thralls(func(t): return in_arc.call(t["x"], t["z"]) and not covered(t["x"], t["z"], p.x, p.z))
		emit_boss("hymn", p.x, p.z, {"r": p.r, "ms": 0, "dir": p.dir})
		return
	if p.kind == "grasp":
		var caught: Array = []
		for c in (p.targets if p.targets != null else []):
			for pl in players:
				if Geom.hyp(pl["x"] - c[0], pl["z"] - c[1]) <= float(C["grasp"]["r"]) + 0.2 and not caught.has(pl["id"]):
					caught.append(pl["id"])
		for pid in caught:
			world.emit({"t": "hurt", "player": pid, "dmg": _dmg(float(C["grasp"]["dmg"])), "from": "boss", "x": p.x, "z": p.z})
		emit_boss("grasp", p.x, p.z, {"targets": p.targets, "r": p.r, "ms": 0, "players": caught, "root": C["grasp"]["rootS"]})
		return
	if p.kind == "maul":
		var mr: float = float(C["melee"]["r"])
		var mh: float = float(C["melee"]["halfDeg"]) * PI / 180.0
		_strike_players(players, func(pl): return Geom.hyp(pl["x"] - p.x, pl["z"] - p.z) <= mr + 0.3 and Geom.angle_diff(Geom.angle_to(p.x, p.z, pl["x"], pl["z"]), p.dir) <= mh, float(C["melee"]["dmg"]), p.x, p.z)
		emit_boss("maul", p.x, p.z, {"r": p.r, "ms": 0, "dir": p.dir})
		return
	super._resolve(p, players)


func _think(dt: float, players: Array) -> void:
	var C := _c
	var s := state
	var ph: int = s["phase"]
	var fast := 0.78 if ph == 3 else (0.9 if ph == 2 else 1.0)
	_hymn_cd -= dt
	_grasp_cd -= dt
	_melee_cd -= dt
	var nn := _nearest(players)
	var nearest: Dictionary = nn["nearest"]
	var nd: float = nn["nd"]
	if not _busy():
		if _hymn_cd <= 0.0:
			_hymn_cd = float(C["hymn"]["cd"]) * fast
			_telegraph("hymn", s["x"], s["z"], float(C["hymn"]["reach"]), float(C["hymn"]["windupMs"]), {"dir": Geom.angle_to(s["x"], s["z"], nearest["x"], nearest["z"])})
		elif _grasp_cd <= 0.0:
			_grasp_cd = float(C["grasp"]["cd"]) * fast
			var lo := int(C["grasp"]["rings"][0])
			var hi := int(C["grasp"]["rings"][1])
			var n := lo + int(floor(world.rand() * float(hi - lo + 1)))
			var targets: Array = []
			for pl in players:
				targets.append([pl["x"], pl["z"]])
			while targets.size() < n:
				var pl2: Dictionary = players[int(floor(world.rand() * players.size()))]
				var a: float = world.rand() * PI * 2.0
				targets.append([pl2["x"] + sin(a) * 2.5, pl2["z"] + cos(a) * 2.5])
			_telegraph("grasp", s["x"], s["z"], float(C["grasp"]["r"]), float(C["grasp"]["windupMs"]), {"targets": targets.slice(0, maxi(n, players.size()))})
		elif _melee_cd <= 0.0 and nd < float(C["melee"]["r"]) + 0.5:
			_melee_cd = float(C["melee"]["cd"]) * fast
			_telegraph("maul", s["x"], s["z"], float(C["melee"]["r"]), float(C["melee"]["windupMs"]), {"dir": Geom.angle_to(s["x"], s["z"], nearest["x"], nearest["z"])})
	# She keeps to the dais and turns to face the nearest singer.
	_chase(nearest, nd, 1.1 * (0.2 if _busy() else 1.0), dt, _ar() - float(C["water"]["dais"]), 2.5)
