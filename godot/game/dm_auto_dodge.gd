class_name DmAutoDodge
extends RefCounted
## One-to-one port of src/gameplay/autoDodge.ts (Easy auto's dodge: leave boss telegraphs, hymn cones and hostile pools).
## Hazards are Dictionaries with the TS keys: {k: circle|cone|seg|rect|except, x, z, r | dir,r,half | dir,len,hw | hw,hd | r,spots,safeR, until, [src], [dir0]}.
## Points are {x, z} Dictionaries; hazards `until` Infinity is INF. Boss events are Dictionaries with the TS SimEvent 'boss' keys.
## Math.hypot -> DmSimMath.hypot, Math.sin/cos/atan2 -> DmFdlibm (V8-exact), Math.round -> DmMath.js_round.

const IN_MARGIN := 0.25
const SAFE_MARGIN := 0.75
const RING_STEP := 0.6
const MAX_ROOM := 3.0
const MAX_RING := 19.0
const ANGLES := 36
const ARRIVED := 0.35
const GOAL_MS := 2500.0


static func _g(o: Variant, name: String, def: Variant = null) -> Variant:
	if o is Dictionary:
		var v: Variant = (o as Dictionary).get(name, def)
		return def if v == null else v
	if o == null:
		return def
	var v2: Variant = (o as Object).get(name)
	return def if v2 == null else v2


static func _hyp(a: float, b: float) -> float:
	return DmSimMath.hypot(a, b)


static func _deg(d: float) -> float:
	return (d * PI) / 180.0


## `${n}` of a JS number (integers without ".0", shortest round-trip digits otherwise).
static func js_str(v: float) -> String:
	if v == floorf(v) and absf(v) < 1e21:
		return str(int(v))
	for dec in range(1, 18):
		var s := String.num(v, dec)
		if s.to_float() == v:
			return s
	return String.num(v, 17)


## A hostile ground pool (`Zone.hostile`): damage over time inside `r` of its centre plus the player's body.
static func pool_hazard(zone: Variant, player_radius: float) -> Dictionary:
	return {"k": "circle", "x": float(_g(zone, "x", 0.0)), "z": float(_g(zone, "z", 0.0)), "r": float(_g(zone, "r", 0.0)) + player_radius, "until": INF}


static func angle_to(fx: float, fz: float, tx: float, tz: float) -> float:
	return DmFdlibm.atan2_(tx - fx, tz - fz)


static func angle_diff(a: float, b: float) -> float:
	var d := fmod(absf(a - b), PI * 2.0)
	return PI * 2.0 - d if d > PI else d


static func seg_dist(px: float, pz: float, ax: float, az: float, bx: float, bz: float) -> float:
	var vx := bx - ax
	var vz := bz - az
	var l2 := vx * vx + vz * vz
	if l2 == 0.0:
		l2 = 1.0
	var t := maxf(0.0, minf(1.0, ((px - ax) * vx + (pz - az) * vz) / l2))
	return _hyp(px - (ax + vx * t), pz - (az + vz * t))


## The half-angle of a boss's melee cone for this event kind (they differ by boss).
static func cone_half(ev: Variant) -> float:
	match str(_g(ev, "kind", "")):
		"sweep": return _deg(float(DmContent.get_export("bosses", "GRAVEDIGGER")["sweep"]["halfDeg"]))
		"swing": return _deg(float(DmContent.get_export("bosses", "SAINT")["swing"]["halfDeg"]))
		"cleave": return _deg(float(DmContent.get_export("bosses", "REGENT")["cleave"]["halfDeg"]))
		"hymn": return _deg(float(DmContent.get_export("bosses", "CONGREGATION")["hymn"]["halfDeg"]))
		"grasp": return _deg(float(DmContent.get_export("bosses", "ABBESS")["grasp"]["halfDeg"]))
	if _g(ev, "boss", "") == "mire":
		return _deg(float(DmContent.get_export("bosses", "MIRE")["maul"]["halfDeg"]))
	return _deg(float(DmContent.get_export("bosses", "CONGREGATION")["melee"]["halfDeg"]))


static func _pairs(targets: Variant) -> Array:
	var out: Array = []
	if targets is Array:
		for t in targets:
			out.append(t)
	return out


## The shapes one boss event warns of (see the TS). `now` is the scene clock in ms.
static func hazards_from_boss_event(ev: Variant, now: float) -> Array:
	var ms := float(_g(ev, "ms", 0.0))
	var kind := str(_g(ev, "kind", ""))
	var evx := float(_g(ev, "x", 0.0))
	var evz := float(_g(ev, "z", 0.0))
	var until := now + ms + 2500.0
	var src := "%s:%s:%s:%s" % [str(_g(ev, "boss", "prelate")), kind, str(DmMath.js_round(evx * 10.0)), str(DmMath.js_round(evz * 10.0))]
	var dir_v: Variant = _g(ev, "dir", null)
	var dir := float(dir_v) if dir_v != null else 0.0
	var tag := {"src": src, "until": until}
	if dir_v != null:
		tag["dir0"] = float(dir_v)
	var targets := _pairs(_g(ev, "targets", []))
	var out: Array = []
	var pad: float = DmSimConsts.BOSS_RING_PAD
	if kind == "pits":
		var G: Dictionary = DmContent.get_export("bosses", "GRAVEDIGGER")
		for t in targets:
			out.append({"k": "circle", "x": float(t[0]), "z": float(t[1]), "r": float(G["pits"]["r"]) + 0.1, "src": "pits:%s:%s" % [js_str(float(t[0])), js_str(float(t[1]))], "until": INF})
		return out
	if ms <= 0.0:
		return []
	var r := float(_g(ev, "r", 0.0))
	match kind:
		"toll", "slam":
			out.append(_mk({"k": "circle", "x": evx, "z": evz, "r": r + pad}, tag))
		"rain", "rotRain", "coals":
			for t in targets:
				out.append(_mk({"k": "circle", "x": float(t[0]), "z": float(t[1]), "r": r + pad}, tag))
		"surface":
			out.append(_mk({"k": "circle", "x": evx, "z": evz, "r": float(DmContent.get_export("bosses", "MIRE")["surface"]["r"]) + 0.3}, tag))
		"hands":
			for t in targets:
				out.append(_mk({"k": "circle", "x": float(t[0]), "z": float(t[1]), "r": float(DmContent.get_export("bosses", "MIRE")["hands"]["r"]) + 0.2}, tag))
		"bury":
			var B: Dictionary = DmContent.get_export("bosses", "GRAVEDIGGER")["burial"]
			for t in targets:
				out.append(_mk({"k": "rect", "x": float(t[0]), "z": float(t[1]), "hw": float(B["hw"]) + 0.3, "hd": float(B["hd"]) + 0.3}, tag))
		"sweep", "swing", "cleave", "maul":
			out.append(_mk({"k": "cone", "x": evx, "z": evz, "dir": dir, "r": r + 0.3, "half": cone_half(ev)}, tag))
		"hymn":
			out.append(_mk({"k": "cone", "x": evx, "z": evz, "dir": dir, "r": float(DmContent.get_export("bosses", "CONGREGATION")["hymn"]["reach"]), "half": cone_half(ev)}, tag))
		"grasp":
			if _g(ev, "boss", "") == "abbess":
				out.append(_mk({"k": "cone", "x": evx, "z": evz, "dir": dir, "r": float(DmContent.get_export("bosses", "ABBESS")["grasp"]["r"]) + 0.3, "half": cone_half(ev)}, tag))
			else:
				for t in targets:
					out.append(_mk({"k": "circle", "x": float(t[0]), "z": float(t[1]), "r": float(DmContent.get_export("bosses", "CONGREGATION")["grasp"]["r"]) + 0.2}, tag))
		"lance":
			var L: Dictionary = DmContent.get_export("bosses", "ABBESS")["lance"]
			out.append(_mk({"k": "seg", "x": evx, "z": evz, "dir": dir, "len": float(L["len"]), "hw": float(L["halfWidth"])}, tag))
		"chorus":
			var C: Dictionary = DmContent.get_export("bosses", "ABBESS")["chorus"]
			var spokes := int(C["spokes"])
			for i in spokes:
				out.append(_mk({"k": "seg", "x": evx, "z": evz, "dir": dir + (i * PI * 2.0) / spokes, "len": float(C["len"]), "hw": float(C["halfWidth"])}, tag))
		"conflagration":
			var spots: Array = []
			for t in targets:
				spots.append([float(t[0]), float(t[1])])
			out.append(_mk({"k": "except", "x": evx, "z": evz, "r": r + 0.5, "spots": spots, "safeR": float(DmContent.get_export("bosses", "REGENT")["conflagration"]["safeR"])}, tag))
	return out


static func _mk(shape: Dictionary, tag: Dictionary) -> Dictionary:
	shape.merge(tag, true)
	return shape


## Is (x, z) struck by the shape? `margin` fattens the shape (or, for `except`, shrinks the safe circles).
static func in_hazard(h: Dictionary, x: float, z: float, margin: float = 0.0) -> bool:
	match h["k"]:
		"circle":
			return _hyp(x - float(h["x"]), z - float(h["z"])) <= float(h["r"]) + margin
		"cone":
			var d := _hyp(x - float(h["x"]), z - float(h["z"]))
			if d > float(h["r"]) + margin:
				return false
			if d <= margin:
				return true
			# A margin of m metres is an angular margin of asin(m / d) at distance d.
			return angle_diff(angle_to(float(h["x"]), float(h["z"]), x, z), float(h["dir"])) <= float(h["half"]) + DmFdlibmX.asin_(minf(1.0, margin / d))
		"seg":
			var dr := float(h["dir"])
			var hx := float(h["x"])
			var hz := float(h["z"])
			var ln := float(h["len"])
			return seg_dist(x, z, hx, hz, hx + DmFdlibm.sin_(dr) * ln, hz + DmFdlibm.cos_(dr) * ln) <= float(h["hw"]) + margin
		"rect":
			return absf(x - float(h["x"])) <= float(h["hw"]) + margin and absf(z - float(h["z"])) <= float(h["hd"]) + margin
		"except":
			if _hyp(x - float(h["x"]), z - float(h["z"])) > float(h["r"]):
				return false
			for s in h["spots"]:
				if _hyp(x - float(s[0]), z - float(s[1])) <= float(h["safeR"]) - margin:
					return false
			return true
	return false


static func any_hazard(hs: Array, x: float, z: float, margin: float) -> bool:
	for h in hs:
		if in_hazard(h, x, z, margin):
			return true
	return false


## The nearest reachable point clear of every shape, or null. opts: {rect: Dictionary|null, nav: DmNav|null, prefer: {x,z}|null}.
static func nearest_safe_point(p: Variant, hazards: Array, opts: Dictionary = {}) -> Variant:
	var rect: Variant = opts.get("rect")
	var nav: Variant = opts.get("nav")
	var prefer: Variant = opts.get("prefer")
	var px := float(_g(p, "x", 0.0))
	var pz := float(_g(p, "z", 0.0))
	var named: Array = []
	for h in hazards:
		if h["k"] == "except":
			for s in h["spots"]:
				named.append({"x": float(s[0]), "z": float(s[1])})
	var spot_dist := func(s: Dictionary) -> float: return _hyp(s["x"] - px, s["z"] - pz)
	named = DmStableSort.sorted(named, func(a, b): return spot_dist.call(a) < spot_dist.call(b))
	var ph: Variant = null
	if prefer != null:
		ph = DmFdlibm.atan2_(float(prefer["x"]) - px, float(prefer["z"]) - pz)
	var ni := 0
	var ring := 1
	while ring * RING_STEP <= MAX_RING:
		var r := ring * RING_STEP
		while ni < named.size() and spot_dist.call(named[ni]) <= r:
			var s: Dictionary = named[ni]
			ni += 1
			if _ok(px, pz, s["x"], s["z"], hazards, rect, nav):
				return s
		var best: Variant = null
		var best_room := -1.0
		var best_turn := INF
		for a in ANGLES:
			var ang := (float(a) / ANGLES) * PI * 2.0
			var x := px + DmFdlibm.sin_(ang) * r
			var z := pz + DmFdlibm.cos_(ang) * r
			if not _ok(px, pz, x, z, hazards, rect, nav):
				continue
			var lo := SAFE_MARGIN
			var hi := MAX_ROOM
			for k in 6:
				var mid := (lo + hi) / 2.0
				if any_hazard(hazards, x, z, mid):
					hi = mid
				else:
					lo = mid
			var room := DmMath.js_round_f(lo * 20.0) / 20.0
			var turn := 0.0 if ph == null else angle_diff(ang, float(ph))
			if room > best_room or (room == best_room and turn < best_turn):
				best = {"x": x, "z": z}
				best_room = room
				best_turn = turn
		if best != null:
			return best
		ring += 1
	return null


static func _ok(px: float, pz: float, x: float, z: float, hazards: Array, rect: Variant, nav: Variant) -> bool:
	if rect != null:
		if x < float(rect["x0"]) + 1.0 or x > float(rect["x1"]) - 1.0 or z < float(rect["z0"]) + 1.0 or z > float(rect["z1"]) - 1.0:
			return false
	if any_hazard(hazards, x, z, SAFE_MARGIN):
		return false
	return nav == null or nav.clear_line(px, pz, x, z, 0.45)


## Easy auto's dodge: a unit direction toward where to stand when the hero is inside a shape (or still on its way to the spot chosen
## for it), null when there is nothing to do. `mem` is the DodgeMemory Dictionary ({goal: {x,z,until}|null}) or null (stateless).
static func dodge_step(p: Variant, hazards: Array, mem: Variant, now: float, opts: Dictionary = {}) -> Variant:
	if hazards.is_empty():
		if mem != null:
			mem["goal"] = null
		return null
	var px := float(_g(p, "x", 0.0))
	var pz := float(_g(p, "z", 0.0))
	var inside := any_hazard(hazards, px, pz, IN_MARGIN)
	var goal: Variant = null
	if mem != null:
		goal = (mem as Dictionary).get("goal")
	if goal != null and (now > float(goal["until"]) or _hyp(float(goal["x"]) - px, float(goal["z"]) - pz) <= ARRIVED):
		goal = null
	# A kept goal must still be clear of what is on the floor now (a new telegraph can land on it).
	if goal != null and any_hazard(hazards, float(goal["x"]), float(goal["z"]), SAFE_MARGIN - 0.2):
		goal = null
	if goal == null:
		if not inside:
			if mem != null:
				mem["goal"] = null
			return null
		var o2 := opts.duplicate()
		o2["prefer"] = (mem as Dictionary).get("goal") if mem != null else null
		var pt: Variant = nearest_safe_point(p, hazards, o2)
		if pt == null:
			if mem != null:
				mem["goal"] = null
			return null
		goal = {"x": pt["x"], "z": pt["z"], "until": now + GOAL_MS}
	if mem != null:
		mem["goal"] = goal
	var d := _hyp(float(goal["x"]) - px, float(goal["z"]) - pz)
	return null if d < 1e-6 else {"x": (float(goal["x"]) - px) / d, "z": (float(goal["z"]) - pz) / d}


## Would a step of `len` metres along `dir` land in (or too near) a live shape?
static func step_into_hazard(p: Variant, dir: Variant, hazards: Array, length: float = 1.4, margin: float = 0.5) -> bool:
	return hazards.size() > 0 and any_hazard(hazards, float(_g(p, "x", 0.0)) + float(dir["x"]) * length, float(_g(p, "z", 0.0)) + float(dir["z"]) * length, margin)
