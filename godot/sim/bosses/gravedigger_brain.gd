class_name DmGravediggerBrain
extends "res://sim/bosses/boss_brain.gd"
## The Gravedigger King: Spade Sweep (cone), Burial (grave outline, rooted), P2 Barrow Ghouls, P3 four open pits. Port of GravediggerBrain.

var _sweep_cd := 2.5
var _bury_cd := 4.0
var _exhume_cd := 0.0
var _elite_done := false
var _pits: Array = []
var _pit_cd: Dictionary = {}
var _g: Dictionary


func _init(world_: RefCounted) -> void:
	super(world_, "gravedigger")
	_g = Content.get_export("bosses", "GRAVEDIGGER")


func _pit_spots() -> Array:
	var out: Array = []
	for p in Content.get_export("bosses", "GRAVEDIGGER_PITS"):
		out.append([float(p[0]), float(p[1])])
	return out


func _on_awaken() -> void:
	_sweep_cd = 2.5
	_bury_cd = 4.0
	_exhume_cd = 4.0
	_elite_done = false
	_pits = []
	_pit_cd.clear()


func _on_phase(p: int) -> void:
	if p == 3:
		# Open Graves: four pits at fixed points around the arena.
		_pits = _pit_spots()
		emit_boss("pits", state["x"], state["z"], {"phase": p, "targets": _pits, "r": _g["pits"]["r"]})


func _on_defeat() -> void:
	_pits = []


## Host migration: the pits are open again if he was already in his last phase.
func resume() -> void:
	_pits = _pit_spots() if int(state["phase"]) >= 3 else []
	_elite_done = float(state["hp"]) / float(state["maxHp"]) <= 0.45


func _tick(dt: float, players: Array) -> void:
	# Walking into an open grave buries you (per-player cooldown so it can't chain-lock).
	if _pits.is_empty():
		return
	var G := _g
	for pl in players:
		var cd: float = float(_pit_cd.get(pl["id"], 0.0)) - dt
		_pit_cd[pl["id"]] = cd
		if cd > 0.0:
			continue
		var pit: Variant = null
		for q in _pits:
			if Geom.hyp(pl["x"] - q[0], pl["z"] - q[1]) <= float(G["pits"]["r"]):
				pit = q
				break
		if pit == null:
			continue
		_pit_cd[pl["id"]] = float(G["pits"]["reburyS"])
		world.emit({"t": "hurt", "player": pl["id"], "dmg": _dmg(float(G["burial"]["dmg"]) * 0.6), "from": "boss", "x": pit[0], "z": pit[1]})
		emit_boss("bury", pit[0], pit[1], {"ms": 0, "players": [pl["id"]], "root": G["burial"]["rootS"]})


func _resolve(p, players: Array) -> void:
	var G := _g
	var s := state
	if p.kind == "sweep":
		var half: float = float(G["sweep"]["halfDeg"]) * PI / 180.0
		var sr: float = float(G["sweep"]["r"])
		var ids := _strike_players(players, func(pl): return Geom.hyp(pl["x"] - p.x, pl["z"] - p.z) <= sr + 0.3 and Geom.angle_diff(Geom.angle_to(p.x, p.z, pl["x"], pl["z"]), p.dir) <= half, float(G["sweep"]["dmg"]), p.x, p.z)
		_hurt_thralls(func(t): return Geom.hyp(t["x"] - p.x, t["z"] - p.z) <= sr and Geom.angle_diff(Geom.angle_to(p.x, p.z, t["x"], t["z"]), p.dir) <= half)
		emit_boss("sweep", p.x, p.z, {"r": p.r, "ms": 0, "dir": p.dir, "players": ids})
		return
	if p.kind == "bury":
		var caught: Array = []
		for gp in (p.targets if p.targets != null else []):
			for pl in players:
				if absf(pl["x"] - gp[0]) <= float(G["burial"]["hw"]) + 0.3 and absf(pl["z"] - gp[1]) <= float(G["burial"]["hd"]) + 0.3 and not caught.has(pl["id"]):
					caught.append(pl["id"])
		for pid in caught:
			world.emit({"t": "hurt", "player": pid, "dmg": _dmg(float(G["burial"]["dmg"])), "from": "boss", "x": p.x, "z": p.z})
		emit_boss("bury", p.x, p.z, {"targets": p.targets, "ms": 0, "players": caught, "root": G["burial"]["rootS"]})
		return
	super._resolve(p, players)


func _think(dt: float, players: Array) -> void:
	var G := _g
	var s := state
	var ph: int = s["phase"]
	var fast := 0.75 if ph == 3 else (0.88 if ph == 2 else 1.0)
	_sweep_cd -= dt
	_bury_cd -= dt
	var nn := _nearest(players)
	var nearest: Dictionary = nn["nearest"]
	var nd: float = nn["nd"]
	if ph >= 2:
		_exhume_cd -= dt
		if _exhume_cd <= 0.0:
			# Exhumation: Barrow Ghouls dug up at the rim (they climb out burrowed).
			_exhume_cd = float(G["exhume"]["everyS"])
			var spots: Array = []
			for i in int(G["exhume"]["ghouls"]):
				var at := _rim(world.rand() * PI * 2.0)
				spots.append(at)
				_spawn_add("ghoul", at[0], at[1])
			emit_boss("summon", s["x"], s["z"], {"targets": spots})
		if not _elite_done and float(s["hp"]) / float(s["maxHp"]) <= 0.45:
			_elite_done = true
			var at2 := _rim(Geom.angle_to(_ax(), _az(), nearest["x"], nearest["z"]) + PI)
			_spawn_add("robber", at2[0], at2[1], true)
	if not _busy():
		if _bury_cd <= 0.0:
			_bury_cd = float(G["burial"]["cd"]) * fast
			# Up to two players (every player in P3) get a grave outline under their feet.
			var marked: Array = players if ph == 3 else _by_distance(players).slice(0, 2)
			var t: Array = []
			for pl in marked:
				t.append([pl["x"], pl["z"]])
			_telegraph("bury", s["x"], s["z"], float(G["burial"]["hd"]), float(G["burial"]["windupMs"]), {"targets": t})
		elif _sweep_cd <= 0.0 and nd < float(G["sweep"]["r"]) + 1.0:
			_sweep_cd = float(G["sweep"]["cd"]) * fast
			var dir := Geom.angle_to(s["x"], s["z"], nearest["x"], nearest["z"])
			_telegraph("sweep", s["x"], s["z"], float(G["sweep"]["r"]), float(G["sweep"]["windupMs"]), {"dir": dir})
			if ph == 3:
				_telegraph("sweep", s["x"], s["z"], float(G["sweep"]["r"]), float(G["sweep"]["windupMs"]), {"dir": dir + PI / 3.0}, 650.0)
	_chase(nearest, nd, (2.6 if ph == 3 else (2.2 if ph == 2 else 1.8)) * (0.3 if _busy() else 1.0), dt, 2.0, 2.5)
