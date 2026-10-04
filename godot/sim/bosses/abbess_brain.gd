class_name DmAbbessBrain
extends "res://sim/bosses/boss_brain.gd"
## The Bone Abbess: four skull niches (targetable enemies) heal her and fire Bone Lances; Ossuary Chorus spokes; P3 rebuilds two
## niches once and channels Bone Communion (devours corpses). Port of AbbessBrain.

var niches: Array = []
var _niche_spots: Array = []
var _broken: Dictionary = {}
var _lance_cd := 4.0
var _chorus_cd := 5.0
var _grasp_cd := 2.0
var _communion_cd := 6.0
var _rebuilt := false
var _a: Dictionary
var _fr: Dictionary


func _init(world_: RefCounted) -> void:
	super(world_, "abbess")
	_a = Content.get_export("bosses", "ABBESS")
	_fr = Content.get_export("abilities", "FRACTURE")


func niche_ids() -> Array:
	return niches


func standing_niches() -> int:
	var n := 0
	for i in niches.size():
		if _alive(i):
			n += 1
	return n


func _spots() -> Array:
	var out: Array = []
	for p in Content.get_export("bosses", "ABBESS_NICHE_SPOTS"):
		out.append([float(p[0]), float(p[1])])
	return out


func _spawn_niche(i: int) -> void:
	var sp: Array = _niche_spots[i]
	var eid: int = world.spawn_enemy("niche", def["area"], sp[0], sp[1], false, false)
	var hp: float = float(state["maxHp"]) * float(_a["nicheHpFrac"])
	world.set_enemy_hp(eid, hp, hp)
	while niches.size() <= i:
		niches.append(null)
	niches[i] = eid
	_broken.erase(i)


func _on_awaken() -> void:
	_niche_spots = _spots()
	niches = []
	_broken.clear()
	_rebuilt = false
	_lance_cd = 4.0
	_chorus_cd = 5.0
	_grasp_cd = 2.0
	_communion_cd = 6.0
	for i in int(_a["niches"]):
		_spawn_niche(i)


func _on_defeat() -> void:
	# The niches crumble with her. Removed outright (like adds), so no death event pays out a kill.
	for eid in niches:
		if eid != null:
			world.remove_enemy(eid)
	niches = []


## Host migration: re-find the standing niches by their fixed spots.
func resume() -> void:
	_niche_spots = _spots()
	niches = []
	_broken.clear()
	for i in _niche_spots.size():
		var sp: Array = _niche_spots[i]
		var found: Variant = null
		for e in world.enemies():
			if e["def"] == "niche" and Geom.hyp(e["x"] - sp[0], e["z"] - sp[1]) < 1.5:
				found = e["id"]
				break
		if found != null:
			niches.append(found)
		else:
			niches.append(-1)
			_broken[i] = true
	_rebuilt = int(state["phase"]) >= 3


func _alive(i: int) -> bool:
	if i < 0 or i >= niches.size() or niches[i] == null:
		return false
	var e: Dictionary = world.enemy_get(niches[i])
	return not e.is_empty() and e["state"] != "dead" and float(e["hp"]) > 0.0


func _on_phase(p: int) -> void:
	if p == 3 and not _rebuilt:
		# Rebuild: two broken niches re-form, once.
		_rebuilt = true
		var n := 0
		var i := 0
		while i < _niche_spots.size() and n < 2:
			if not _alive(i):
				_spawn_niche(i)
				n += 1
			i += 1
		if n:
			emit_boss("summon", state["x"], state["z"], {"phase": p, "targets": _niche_spots})


func _tick(dt: float, players: Array) -> void:
	var s := state
	var standing := 0
	for i in niches.size():
		if _alive(i):
			standing += 1
			continue
		if _broken.has(i):
			continue
		# A niche broke: it tears at her (4% max health) and Fractures her.
		_broken[i] = true
		s["hp"] = float(s["hp"]) - float(s["maxHp"]) * float(_a["nicheBreakFrac"])
		s["flash"] = 1.0
		s["fracture"] = mini(int(_fr["maxStacks"]), int(s["fracture"]) + 1)
		s["fractureT"] = float(_fr["durationMs"]) / 1000.0
		var sp: Array = _niche_spots[i]
		emit_boss("nicheBreak", sp[0], sp[1])
	if standing > 0:
		s["hp"] = minf(float(s["maxHp"]), float(s["hp"]) + float(s["maxHp"]) * float(_a["regenPerS"]) * dt)
		_lance_cd -= dt
		if _lance_cd <= 0.0 and not players.is_empty():
			# A Bone Lance from a standing niche at a random player.
			_lance_cd = float(_a["lance"]["everyS"])
			var up: Array = []
			for i in _niche_spots.size():
				if _alive(i):
					up.append(_niche_spots[i])
			var nsp: Array = up[int(floor(world.rand() * up.size()))]
			var pl: Dictionary = players[int(floor(world.rand() * players.size()))]
			_telegraph("lance", nsp[0], nsp[1], float(_a["lance"]["len"]), float(_a["lance"]["windupMs"]), {"dir": Geom.angle_to(nsp[0], nsp[1], pl["x"], pl["z"]), "side": true})


func _tip(p, length: float, dir: float) -> Array:
	return [p.x + sin(dir) * length, p.z + cos(dir) * length]


func _resolve(p, players: Array) -> void:
	var A := _a
	var s := state
	if p.kind == "lance":
		var b := _tip(p, float(A["lance"]["len"]), p.dir)
		var hw: float = float(A["lance"]["halfWidth"])
		_strike_players(players, func(pl): return Geom.seg_dist(pl["x"], pl["z"], p.x, p.z, b[0], b[1]) <= hw, float(A["lance"]["dmg"]), p.x, p.z)
		_hurt_thralls(func(t): return Geom.seg_dist(t["x"], t["z"], p.x, p.z, b[0], b[1]) <= hw)
		emit_boss("lance", p.x, p.z, {"r": p.r, "ms": 0, "dir": p.dir})
		return
	if p.kind == "chorus":
		var n := int(A["chorus"]["spokes"])
		var spokes: Array = []
		for i in n:
			spokes.append(float(p.dir) + (float(i) * PI * 2.0) / float(n))
		var clen: float = float(A["chorus"]["len"])
		var chw: float = float(A["chorus"]["halfWidth"])
		var on_spoke := func(x: float, z: float) -> bool:
			for d in spokes:
				var tb := _tip(p, clen, d)
				if Geom.seg_dist(x, z, p.x, p.z, tb[0], tb[1]) <= chw:
					return true
			return false
		_strike_players(players, func(pl): return on_spoke.call(pl["x"], pl["z"]), float(A["chorus"]["dmg"]), p.x, p.z)
		_hurt_thralls(func(t): return on_spoke.call(t["x"], t["z"]))
		emit_boss("chorus", p.x, p.z, {"r": p.r, "ms": 0, "dir": p.dir})
		return
	if p.kind == "grasp":
		var gr: float = float(A["grasp"]["r"])
		var gh: float = float(A["grasp"]["halfDeg"]) * PI / 180.0
		_strike_players(players, func(pl): return Geom.hyp(pl["x"] - p.x, pl["z"] - p.z) <= gr + 0.3 and Geom.angle_diff(Geom.angle_to(p.x, p.z, pl["x"], pl["z"]), p.dir) <= gh, float(A["grasp"]["dmg"]), p.x, p.z)
		emit_boss("grasp", p.x, p.z, {"r": p.r, "ms": 0, "dir": p.dir})
		return
	if p.kind == "communion":
		# Every corpse still in the arena crawls to her and feeds her.
		var fed := 0
		for c in world.corpses():
			if c["area"] != def["area"] or Geom.hyp(c["x"] - _ax(), c["z"] - _az()) > _ar():
				continue
			world.remove_corpse(c["id"], "devoured")
			fed += 1
		s["hp"] = minf(float(s["maxHp"]), float(s["hp"]) + float(s["maxHp"]) * float(A["communion"]["healPerCorpse"]) * float(fed))
		emit_boss("communion", p.x, p.z, {"ms": 0, "r": fed})
		return
	super._resolve(p, players)


func _think(dt: float, players: Array) -> void:
	var A := _a
	var s := state
	var ph: int = s["phase"]
	var fast := 0.8 if ph == 3 else (0.9 if ph == 2 else 1.0)
	_chorus_cd -= dt
	_grasp_cd -= dt
	if ph == 3:
		_communion_cd -= dt
	var nn := _nearest(players)
	var nearest: Dictionary = nn["nearest"]
	var nd: float = nn["nd"]
	if not _busy():
		if ph == 3 and _communion_cd <= 0.0:
			_communion_cd = float(A["communion"]["cd"])
			var corpses: Array = []
			for c in world.corpses():
				if c["area"] == def["area"] and Geom.hyp(c["x"] - _ax(), c["z"] - _az()) <= _ar():
					corpses.append([c["x"], c["z"]])
			_telegraph("communion", s["x"], s["z"], _ar(), float(A["communion"]["channelS"]) * 1000.0, {"targets": corpses})
		elif _chorus_cd <= 0.0:
			_chorus_cd = float(A["chorus"]["cd"]) * fast
			var dir: float = world.rand() * PI * 2.0
			_telegraph("chorus", s["x"], s["z"], float(A["chorus"]["len"]), float(A["chorus"]["windupMs"]), {"dir": dir})
			if ph >= 2:
				_telegraph("chorus", s["x"], s["z"], float(A["chorus"]["len"]), float(A["chorus"]["windupMs"]), {"dir": dir + (float(A["chorus"]["rotateDeg"]) * PI) / 180.0}, 900.0)
		elif _grasp_cd <= 0.0 and nd < float(A["grasp"]["r"]) + 0.5:
			_grasp_cd = float(A["grasp"]["cd"]) * fast
			_telegraph("grasp", s["x"], s["z"], float(A["grasp"]["r"]), float(A["grasp"]["windupMs"]), {"dir": Geom.angle_to(s["x"], s["z"], nearest["x"], nearest["z"])})
	_chase(nearest, nd, (2.0 if ph == 3 else (1.7 if ph == 2 else 1.4)) * (0.25 if _busy() else 1.0), dt, 2.5, 2.8)
