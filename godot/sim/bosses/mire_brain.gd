class_name DmMireBrain
extends "res://sim/bosses/boss_brain.gd"
## The Mire Mother: sinks and resurfaces under a hummock (ripple ring, then winded), Drowned Hands root wading players, P2 floods the
## arena, P3 she raises a Risen from every corpse in the Fen (starve the rite and she staggers). Port of MireMotherBrain.

var _surface_cd := 6.0
var _maul_cd := 2.0
var _hands_cd := 4.0
var _rite_cd := 10.0
## The hummock she is surfacing under (index into FEN_HUMMOCKS), or -1 while she walks.
var _spot := -1
var _m: Dictionary
var _hummocks: Array
var _surface_spots: Array
var _flood: Dictionary


func _init(world_: RefCounted) -> void:
	super(world_, "mire")
	_m = Content.get_export("bosses", "MIRE")
	_hummocks = Content.get_export("fen", "FEN_HUMMOCKS")
	_surface_spots = Content.get_export("fen", "FEN_SURFACE_SPOTS")
	_flood = Content.get_export("fen", "FEN_FLOOD_SCALE")


func _flood_scale(phase: int) -> float:
	return float(_flood[str(phase)])


func _on_awaken() -> void:
	_surface_cd = 6.0
	_maul_cd = 2.0
	_hands_cd = 4.0
	_rite_cd = 10.0
	_spot = -1
	# She rises on the central hummock.
	state["x"] = float(_hummocks[1]["x"])
	state["z"] = float(_hummocks[1]["z"])


func resume() -> void:
	_spot = -1
	if state["state"] == "sunk":
		state["state"] = "idle"
	_surface_cd = 6.0
	_hands_cd = 4.0
	_rite_cd = 10.0


## Nothing hurts her while she is under the water.
func damage(amount: float, by: String, fracture: int) -> void:
	if state["state"] == "sunk":
		return
	super.damage(amount, by, fracture)


func _on_defeat() -> void:
	_spot = -1


func _on_phase(p: int) -> void:
	var wave: Array = _m["adds"]["p2"] if p == 2 else (_m["adds"]["p3"] if p == 3 else [])
	var spots: Array = []
	for i in wave.size():
		var at := _rim((float(i) / float(wave.size())) * PI * 2.0 + 0.35, 0.9)
		spots.append(at)
		_spawn_add(wave[i], at[0], at[1])
	# The flood itself is read from the phase (content/fen.ts FEN_FLOOD_SCALE): the event is the moment to show it.
	emit_boss("flood", state["x"], state["z"], {"phase": p, "targets": spots})


## Corpses lying in the Fen right now (a corpse may be claimed by anything: Exhume, Litany, Offering, a detonation).
func _fen_corpses() -> Array:
	var mine: Array = []
	for c in world.corpses():
		if c["area"] == def["area"]:
			mine.append(c)
	var sorted_c: Array = StableSort.sorted(mine, func(a, b): return (Geom.hyp(a["x"] - _ax(), a["z"] - _az()) - Geom.hyp(b["x"] - _ax(), b["z"] - _az())) < 0.0)
	return sorted_c.slice(0, int(_m["rite"]["maxCorpses"]))


func _resolve(p, players: Array) -> void:
	var M_ := _m
	var s := state
	if p.kind == "surface":
		var h: Dictionary = _hummocks[_spot] if _spot >= 0 and _spot < _hummocks.size() else _hummocks[1]
		_spot = -1
		var hx: float = h["x"]
		var hz: float = h["z"]
		s["x"] = hx
		s["z"] = hz
		s["state"] = "idle"
		s["stateT"] = 0.0
		var sr: float = float(M_["surface"]["r"])
		_strike_players(players, func(pl): return Geom.hyp(pl["x"] - hx, pl["z"] - hz) <= sr + 0.3, float(M_["surface"]["dmg"]), hx, hz)
		_hurt_thralls(func(t): return Geom.hyp(t["x"] - hx, t["z"] - hz) <= sr, float(M_["surface"]["dmg"]) * 0.6)
		emit_boss("surface", hx, hz, {"r": sr, "ms": 0})
		# Winded: a real window to hit her (the brain pauses while staggered).
		stagger(float(M_["surface"]["windedS"]))
		return
	if p.kind == "hands":
		var hr: float = float(M_["hands"]["r"])
		var caught: Array = []
		for c in (p.targets if p.targets != null else []):
			for pl in players:
				if Geom.hyp(pl["x"] - c[0], pl["z"] - c[1]) <= hr + 0.2 and not caught.has(pl["id"]):
					caught.append(pl["id"])
		for pid in caught:
			world.emit({"t": "hurt", "player": pid, "dmg": _dmg(float(M_["hands"]["dmg"])), "from": "boss", "x": p.x, "z": p.z})
		var in_ring := func(t) -> bool:
			for c in (p.targets if p.targets != null else []):
				if Geom.hyp(t["x"] - c[0], t["z"] - c[1]) <= hr:
					return true
			return false
		_hurt_thralls(in_ring, float(M_["hands"]["dmg"]))
		emit_boss("hands", p.x, p.z, {"targets": p.targets, "r": p.r, "ms": 0, "players": caught, "root": M_["hands"]["rootS"]})
		return
	if p.kind == "maul":
		var mr: float = float(M_["maul"]["r"])
		var mh: float = float(M_["maul"]["halfDeg"]) * PI / 180.0
		_strike_players(players, func(pl): return Geom.hyp(pl["x"] - p.x, pl["z"] - p.z) <= mr + 0.3 and Geom.angle_diff(Geom.angle_to(p.x, p.z, pl["x"], pl["z"]), p.dir) <= mh, float(M_["maul"]["dmg"]), p.x, p.z)
		_hurt_thralls(func(t): return Geom.hyp(t["x"] - p.x, t["z"] - p.z) <= mr and Geom.angle_diff(Geom.angle_to(p.x, p.z, t["x"], t["z"]), p.dir) <= mh)
		emit_boss("maul", p.x, p.z, {"r": p.r, "ms": 0, "dir": p.dir})
		return
	if p.kind == "rite":
		# Drowned thralls rise from whatever corpses are still lying in the Fen.
		var at: Array = []
		for c in _fen_corpses():
			at.append([c["x"], c["z"]])
			world.remove_corpse(c["id"], "raised")
			_spawn_add("risen", c["x"], c["z"])
		emit_boss("rite", s["x"], s["z"], {"targets": at, "r": at.size(), "ms": 0})
		if at.is_empty():
			stagger(float(M_["rite"]["failStaggerS"]))
		return
	super._resolve(p, players)


func _think(dt: float, players: Array) -> void:
	var M_ := _m
	var s := state
	if s["state"] == "sunk":
		return # under the water until the ripple ring fills
	var ph: int = s["phase"]
	var pi_ := ph - 1
	var fast := 0.8 if ph == 3 else (0.9 if ph == 2 else 1.0)
	_surface_cd -= dt
	_maul_cd -= dt
	_hands_cd -= dt
	if ph == 3:
		_rite_cd -= dt
	var nn := _nearest(players)
	var nearest: Dictionary = nn["nearest"]
	var nd: float = nn["nd"]
	if not _busy():
		if ph == 3 and _rite_cd <= 0.0:
			_rite_cd = float(M_["rite"]["cd"]) * fast
			# The beams are drawn to the corpses that exist right now; whatever is gone by the end of the windup is denied her.
			var ct: Array = []
			for c in _fen_corpses():
				ct.append([c["x"], c["z"]])
			_telegraph("rite", s["x"], s["z"], _ar(), float(M_["rite"]["windupMs"]), {"targets": ct})
		elif _surface_cd <= 0.0:
			_surface_cd = float(M_["surface"]["cd"][pi_])
			# She hunts: usually the hummock a player is standing on, otherwise any of the ring.
			var scale := _flood_scale(ph)
			var standing: Array = []
			for i in _surface_spots:
				var hm: Dictionary = _hummocks[int(i)]
				for pl in players:
					if Geom.hyp(pl["x"] - float(hm["x"]), pl["z"] - float(hm["z"])) <= float(hm["r"]) * scale + 0.5:
						standing.append(i)
						break
			var pool: Array = _surface_spots
			if not standing.is_empty() and world.rand() < float(M_["surface"]["huntChance"]):
				pool = standing
			_spot = int(pool[int(floor(world.rand() * pool.size()))])
			var h: Dictionary = _hummocks[_spot]
			_telegraph("surface", h["x"], h["z"], float(M_["surface"]["r"]), float(M_["surface"]["windupMs"][pi_]))
			# She slips under now; the ring fills over her new hummock.
			s["state"] = "sunk"
			s["stateT"] = 0.0
			s["x"] = h["x"]
			s["z"] = h["z"]
			return
		elif _hands_cd <= 0.0:
			_hands_cd = float(M_["hands"]["cd"][pi_])
			var lo := int(M_["hands"]["rings"][0])
			var hi := int(M_["hands"]["rings"][1])
			var n := lo + int(floor(world.rand() * float(hi - lo + 1)))
			# Hands reach for anyone wading the open water (players on dry ground are safe from them).
			var wading: Array = []
			for pl in players:
				if Geom.in_bog(pl["x"], pl["z"]) and not Geom.on_hummock(pl["x"], pl["z"], _flood_scale(ph)):
					wading.append(pl)
			var targets: Array = []
			for pl in wading:
				targets.append([pl["x"], pl["z"]])
			while targets.size() < n:
				var a: float = world.rand() * PI * 2.0
				var r: float = 2.0 + world.rand() * (_ar() - 3.0)
				targets.append([_ax() + sin(a) * r, _az() + cos(a) * r])
			_telegraph("hands", s["x"], s["z"], float(M_["hands"]["r"]), float(M_["hands"]["windupMs"]), {"targets": targets.slice(0, maxi(n, wading.size()))})
		elif _maul_cd <= 0.0 and nd < float(M_["maul"]["r"]) + 0.5:
			_maul_cd = float(M_["maul"]["cd"]) * fast
			_telegraph("maul", s["x"], s["z"], float(M_["maul"]["r"]), float(M_["maul"]["windupMs"]), {"dir": Geom.angle_to(s["x"], s["z"], nearest["x"], nearest["z"])})
	_chase(nearest, nd, (2.0 if ph == 3 else (1.75 if ph == 2 else 1.5)) * (0.3 if _busy() else 1.0), dt, 2.5, 2.8)
