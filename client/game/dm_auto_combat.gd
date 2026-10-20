class_name DmAutoCombat
extends RefCounted
## One-to-one port of archive/legacy-web:src/gameplay/autoCombat.ts (Easy auto's combat decision + movement).
##
## select_action(ctx) = selectAutoCombatAction. ctx keys are the TS AutoCombatInput names:
##   player {x, z, essence, maxEssence, [hp, maxHp, area, veilForm, bulwarkUntil, betweenUntil, unbreakableUntil]},
##   enemies (Array or id->enemy Dictionary of DmSimEnemy / Dictionaries), corpses (same, DmSimCorpse), boss (DmBossState or Dictionary),
##   thrallCount, thrallCap, ready (Callable(id: String) -> bool), [primary, primaryRange, selfId, family, signature, now].
## Returns null or {"id": String, "target": {x, z, [boss: true | enemyId]}}.
## select_movement(ctx, mem, now, dt) = selectAutoCombatMovement: ctx also carries [nav: DmNav, routeNav, hazards: Array of dm_auto_dodge hazards].
## `nav` serves the walk toward a target and the dodge's spots; `routeNav` (the game on the navmesh, where the dodge's many candidate spots would each cost a query) serves the walk toward
## a target only, and stands in for `nav` there. Both answer `clear_line(ax, az, bx, bz, r)` and `find_path(fx, fz, tx, tz, r)` (Array of [x, z]).
## `mem` is the AutoMoveMemory Dictionary, mutated in place (null = stateless); the caller may set `stuckUntil` (ms) to make the walk take the route round whatever holds the hero.
## Returns null or {x, z}.
## Optional TS fields are read through _g(): a missing key, null, or (for sim objects) the field default stands for "undefined".

const BOSS_RADIUS: float = DmSimConsts.BOSS_RADIUS
const STICKY_TARGET_M := 2.0
const CLOSE_START := 0.2
const CLOSE_STOP := 1.1
const EVADE_COMMIT_MS := 450.0
const TURN_SECONDS := 0.1
const SIGHT_MS := 200.0   ## how often the walk looks along the straight line to its target
const ROUTE_MS := 800.0   ## how long a route round something in the way is followed before it is asked for again


static func _g(o: Variant, name: String, def: Variant = null) -> Variant:
	if o is Dictionary:
		var v: Variant = (o as Dictionary).get(name, def)
		return def if v == null else v
	if o == null:
		return def
	var v2: Variant = (o as Object).get(name)
	return def if v2 == null else v2


## JS truthiness.
static func _tr(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL: return false
		TYPE_BOOL: return v
		TYPE_INT: return v != 0
		TYPE_FLOAT: return v != 0.0 and not is_nan(v)
		TYPE_STRING, TYPE_STRING_NAME: return str(v) != ""
	return true


static func _list(src: Variant) -> Array:
	if src is Array:
		return src
	if src is Dictionary:
		return (src as Dictionary).values()
	if src is PackedInt32Array or src is PackedFloat64Array:
		return Array(src)
	return []


## An object's fields as a Dictionary (the names the decisions read), so an enemy or corpse that is a sim object is read the way the adapter's dictionaries are.
static func _fields(o: Variant) -> Dictionary:
	var out := {}
	if o == null:
		return out
	for k in ["hp", "state", "area", "x", "z", "id", "radius", "elite", "maxHp", "hexOwner", "kind", "seedOwner", "echoOwner"]:
		out[k] = (o as Object).get(k)
	return out


static func _ab(id: String) -> Dictionary:
	return DmContent.ability(id)


static func _dist(a: Variant, b: Variant) -> float:
	return DmSimMath.hypot(float(_g(a, "x", 0.0)) - float(_g(b, "x", 0.0)), float(_g(a, "z", 0.0)) - float(_g(b, "z", 0.0)))


static func _pt(a: Variant) -> Dictionary:
	return {"x": float(_g(a, "x", 0.0)), "z": float(_g(a, "z", 0.0))}


## A corpse as a plain Dictionary (echoOwner "" = undefined, like the sim object).
static func _corpse(c: Variant) -> Dictionary:
	var eo: Variant = _g(c, "echoOwner", null)
	if eo is String and eo == "":
		eo = null
	return {"x": float(_g(c, "x", 0.0)), "z": float(_g(c, "z", 0.0)), "kind": str(_g(c, "kind", "normal")), "seedOwner": _g(c, "seedOwner", ""),
		"echoOwner": eo, "area": str(_g(c, "area", ""))}


static func _aim(t: Variant) -> Dictionary:
	var out := {"x": float(_g(t, "x", 0.0)), "z": float(_g(t, "z", 0.0))}
	if _tr(_g(t, "boss", null)):
		out["boss"] = true
	elif _g(t, "enemyId", null) != null:
		out["enemyId"] = _g(t, "enemyId")
	return out


static func _action(id: String, t: Variant) -> Dictionary:
	return {"id": id, "target": _aim(t)}


## `arr`'s dictionaries by their "distance", equal distances in their order (JS's sort is stable, Godot's `sort_custom` is not): [distance, position] pairs sorted natively (an array
## compares its first element, then its second), the dictionaries picked out in that order. The merge sort with a lambda it replaces took 1 ms for 64 targets.
static func _by_distance(arr: Array) -> Array:
	var n := arr.size()
	if n < 2:
		return arr.duplicate()
	var keyed: Array = []
	keyed.resize(n)
	for i in n:
		keyed[i] = [arr[i]["distance"], i]
	keyed.sort()
	var out: Array = []
	out.resize(n)
	for i in n:
		out[i] = arr[(keyed[i] as Array)[1]]
	return out


## One Easy-auto combat decision. Returns null or {id, target}.
## Same decisions as the TS function, with its cost cut (Gravecaller, 62 enemies and 31 corpses in reach: 3.0 ms a decision on the VPS, 6.6 ms when it ends in Corpse Explosion,
## which is a 14 ms physics tick; now see "The benchmark" in client/README.md): the sorts are native (`_by_distance`, the corpses' `keyed`), the field reads are made once per body, and the
## counting rites run on packed arrays (`_around`, `_knot`) instead of a lambda calling `_dist` for every pair.
static func select_action(ctx: Dictionary) -> Variant:
	var p: Variant = ctx["player"]
	var px := float(_g(p, "x", 0.0))
	var pz := float(_g(p, "z", 0.0))
	var essence := float(_g(p, "essence", 0.0))
	var max_essence := float(_g(p, "maxEssence", 0.0))
	var p_area: String = str(_g(p, "area", ""))
	var boss: Variant = ctx.get("boss")
	var thrall_count := int(ctx.get("thrallCount", 0))
	var thrall_cap := int(ctx.get("thrallCap", 0))
	var ready: Callable = ctx["ready"]
	var p_pt := {"x": px, "z": pz}
	var miasma_range := float(_ab("miasma")["range"])
	var targets: Array = []
	var inspected := 0
	for e in _list(ctx.get("enemies")):
		inspected += 1
		if inspected > 512:
			break
		var ed: Dictionary = e if e is Dictionary else _fields(e)
		var v: Variant = ed.get("hp")
		var hp := 0.0 if v == null else float(v)
		v = ed.get("state")
		var st := "" if v == null else str(v)
		if hp <= 0.0 or st == "dead" or st == "rising" or st == "burrow":
			continue
		if p_area != "":
			v = ed.get("area")
			var e_area := "" if v == null else str(v)
			if e_area != "" and e_area != p_area:
				continue
		v = ed.get("x")
		var ex := 0.0 if v == null else float(v)
		v = ed.get("z")
		var ez := 0.0 if v == null else float(v)
		var d := DmSimMath.hypot(px - ex, pz - ez)   # (_dist(p_pt, e))
		if d <= miasma_range:
			var v_id: Variant = ed.get("id")
			var v_rad: Variant = ed.get("radius")
			var v_elite: Variant = ed.get("elite")
			var v_hex: Variant = ed.get("hexOwner")
			targets.append({"x": ex, "z": ez, "enemyId": 0 if v_id == null else v_id, "radius": 0.5 if v_rad == null else float(v_rad), "distance": d,
				"elite": false if v_elite == null else v_elite, "hp": hp, "maxHp": ed.get("maxHp"), "state": st, "hexOwner": "" if v_hex == null else v_hex})
	targets = _by_distance(targets)
	if targets.size() > 64:
		targets.resize(64)
	if boss != null and bool(_g(boss, "active", false)) and float(_g(boss, "hp", 0.0)) > 0.0 and str(_g(boss, "state", "")) != "dead":
		var bd := _dist(p_pt, boss)
		if bd <= miasma_range:
			var at := targets.size()   # (the boss sorts in after every target at its distance or nearer: the stable sort of the list with the boss appended)
			while at > 0 and float(targets[at - 1]["distance"]) > bd:
				at -= 1
			targets.insert(at, {"x": float(_g(boss, "x", 0.0)), "z": float(_g(boss, "z", 0.0)), "boss": true, "radius": BOSS_RADIUS, "distance": bd})
	if targets.is_empty():
		return null
	var family: Variant = ctx.get("family")
	if family == "reaper":
		return _reaper_action(ctx, targets)
	if _tr(family) and family != "necromancer":
		return _new_blood_action(ctx, targets)
	# Always retain a little essence for player-directed spells. Low essence uses the free generator.
	var reserve := maxf(12.0, max_essence * 0.2)
	var can_spend := func(id: String) -> bool:
		return ready.call(id) and essence >= float(_ab(id)["essenceCost"]) + reserve
	var primary: String = str(ctx.get("primary", "bone_needle")) if ctx.get("primary") != null else "bone_needle"
	var prim_range: Variant = ctx.get("primaryRange")
	var reach_p: float = float(prim_range) if prim_range != null else float(_ab(primary)["range"])
	var in_reach: Array = []
	for t in targets:
		if float(t["distance"]) <= reach_p + (BOSS_RADIUS if t.has("boss") else 0.4):
			in_reach.append(t)
	var needle: Variant = _primary_target(primary, in_reach)
	if essence < max_essence * 0.35 and needle != null and ready.call(primary):
		return _action(primary, needle)

	var corpses: Array = []
	var keyed: Array = []   # [distance from the hero, position in `corpses`]: sorted natively below, the position keeping equal distances in order
	inspected = 0
	var exhume_range := float(_ab("exhume")["range"])
	for c in _list(ctx.get("corpses")):
		inspected += 1
		if inspected > 256:
			break
		var cf: Dictionary = c if c is Dictionary else _fields(c)
		var v: Variant = cf.get("kind")
		var kind := "normal" if v == null else str(v)
		if kind == "none":
			continue
		v = cf.get("x")
		var cx := 0.0 if v == null else float(v)
		v = cf.get("z")
		var cz := 0.0 if v == null else float(v)
		var cd := DmSimMath.hypot(px - cx, pz - cz)   # (_dist(p_pt, c))
		if cd <= exhume_range:
			keyed.append([cd, corpses.size()])
			var echo: Variant = cf.get("echoOwner")
			if echo is String and echo == "":
				echo = null   # (like _corpse: "" = undefined)
			var v_seed: Variant = cf.get("seedOwner")
			v = cf.get("area")
			corpses.append({"x": cx, "z": cz, "kind": kind, "seedOwner": "" if v_seed == null else v_seed, "echoOwner": echo, "area": "" if v == null else str(v)})
	if keyed.size() > 1:
		keyed.sort()
		var nearest_first: Array = []
		for k: Array in keyed:
			nearest_first.append(corpses[k[1]])
		corpses = nearest_first
	if corpses.size() > 32:
		corpses.resize(32)
	var cn := corpses.size()
	var kx := PackedFloat64Array()
	var kz := PackedFloat64Array()
	kx.resize(cn)
	kz.resize(cn)
	for i in cn:
		kx[i] = corpses[i]["x"]
		kz[i] = corpses[i]["z"]
	var tn := targets.size()
	var tx := PackedFloat64Array()
	var tz := PackedFloat64Array()
	var trd := PackedFloat64Array()
	tx.resize(tn)
	tz.resize(tn)
	trd.resize(tn)
	for i in tn:
		tx[i] = targets[i]["x"]
		tz[i] = targets[i]["z"]
		trd[i] = targets[i]["radius"]
	if thrall_count < thrall_cap and cn > 0 and can_spend.call("exhume"):
		return _action("exhume", corpses[0])
	# Grave Offering: only when essence is low AND the legion is full; resonant corpses are kept back for Litany.
	if essence < max_essence * 0.3 and thrall_count >= thrall_cap and ready.call("grave_offering"):
		var go_range := float(_ab("grave_offering")["range"])
		for i in cn:
			var c: Dictionary = corpses[i]
			if c["kind"] != "resonant" and not _tr(c["seedOwner"]) and DmSimMath.hypot(px - kx[i], pz - kz[i]) <= go_range:
				return _action("grave_offering", c)
	var t0: Dictionary = targets[0]
	# Rally the Dead: a legion of three or more with the enemy close.
	if thrall_count >= 3 and can_spend.call("rally_dead") and float(t0["distance"]) <= 8.0:
		return _action("rally_dead", t0)
	# Carrion Seed: one live seed; plant it on the corpse nearest the approaching pack.
	var self_id: Variant = ctx.get("selfId")
	if can_spend.call("carrion_seed"):
		var has_seed := false
		for c in corpses:
			if _tr(c["seedOwner"]) and c["seedOwner"] == self_id:
				has_seed = true
				break
		if not has_seed:
			var best: Variant = null
			var best_d := 6.0
			for i in cn:
				var c: Dictionary = corpses[i]
				if _tr(c["seedOwner"]):
					continue
				var d := DmSimMath.hypot(kx[i] - float(t0["x"]), kz[i] - float(t0["z"]))   # (_dist(c, t0))
				if d > 1.5 and d < best_d:
					best = c
					best_d = d
			if best != null:
				return _action("carrion_seed", best)

	var hp_v: Variant = _g(p, "hp", null)
	var max_hp_v: Variant = _g(p, "maxHp", null)
	var has_hp: bool = hp_v != null and _tr(max_hp_v)
	# Bone Mantle: armour up when the pack is on you and you are hurt, or when the dead lie thick.
	if can_spend.call("bone_mantle") and _around(px, pz, 3.0, tx, tz, trd) >= 2:
		var hurt: bool = float(hp_v) < float(max_hp_v) * 0.6 if has_hp else false
		var fuel := 0
		var mr := float(_ab("bone_mantle")["radius"])
		for i in cn:
			if DmSimMath.hypot(px - kx[i], pz - kz[i]) <= mr:
				fuel += 1
		if hurt or fuel >= 3:
			return _action("bone_mantle", p_pt)
	# The automatic ritual never destroys the player's army: a large fight with actual corpse fuel only.
	var litany_r := float(_ab("black_litany")["radius"])
	if thrall_count == 0:
		var lc := 0
		for i in cn:
			if DmSimMath.hypot(px - kx[i], pz - kz[i]) <= litany_r:
				lc += 1
		if lc >= 2 and _around(px, pz, litany_r, tx, tz, trd) >= 6 and can_spend.call("black_litany"):
			return _action("black_litany", p_pt)
	if can_spend.call("corpse_explosion"):
		var D: Dictionary = DmContent.get_export("abilities", "DETONATE")
		var best_c: Variant = null
		var hits := 1
		for i in cn:
			var c: Dictionary = corpses[i]
			var r := float(D["radius"]) * (float(D["resonantRadiusMult"]) if c["kind"] == "resonant" else 1.0)
			var count := _around(kx[i], kz[i], r, tx, tz, trd)
			if count > hits:
				best_c = c
				hits = count
		if best_c != null:
			return _action("corpse_explosion", best_c)
	var candidates: Array = targets.slice(0, 12)
	# Ivory Cleave: two or more within the crescent in front of the nearest enemy.
	var IC: Dictionary = DmContent.get_export("abilities", "IVORY_CLEAVE")
	if can_spend.call("ivory_cleave") and float(t0["distance"]) <= float(IC["reach"]) + float(t0["radius"]):
		var d0 := maxf(0.01, float(t0["distance"]))
		var cs := DmFdlibm.cos_((float(IC["halfAngleDeg"]) * PI) / 180.0)
		var in_arc := 0
		for e in targets:
			var d: float = e["distance"]
			if d > float(IC["reach"]) + float(e["radius"]):
				continue
			if d < float(e["radius"]) or ((float(e["x"]) - px) * (float(t0["x"]) - px) + (float(e["z"]) - pz) * (float(t0["z"]) - pz)) / (d * d0) >= cs:
				in_arc += 1
		if in_arc >= 2:
			return _action("ivory_cleave", t0)
	if can_spend.call("miasma"):
		var best_m: Variant = null
		var hits_m := 2
		var miasma_r := float(_ab("miasma")["radius"])
		for i in candidates.size():
			var count := _around(tx[i], tz[i], miasma_r, tx, tz, trd)
			if count > hits_m:
				best_m = candidates[i]
				hits_m = count
		if best_m != null:
			return _action("miasma", best_m)
	# Grimoire expansion: a cage, a field and a storm want a knot of three or more; the siphon wants a sturdy target, or answers pressure.
	if can_spend.call("bone_prison"):
		var t: Variant = _knot("bone_prison", float(_ab("bone_prison")["radius"]), 3, candidates, tx, tz, trd)
		if t != null:
			return _action("bone_prison", t)
	if can_spend.call("grave_hands"):
		var t: Variant = _knot("grave_hands", float(_ab("grave_hands")["radius"]), 3, candidates, tx, tz, trd)
		if t != null:
			return _action("grave_hands", t)
	if can_spend.call("bone_storm"):
		var t: Variant = _knot("bone_storm", float(_ab("bone_storm")["radius"]) + 1.0, 3, candidates, tx, tz, trd)
		if t != null:
			return _action("bone_storm", t)
	if can_spend.call("soul_siphon"):
		var hurt_now: bool = float(hp_v) < float(max_hp_v) * 0.7 if has_hp else false
		var ss_range := float(_ab("soul_siphon")["range"])
		var prey: Variant = null
		for t in candidates:
			if float(t["distance"]) <= ss_range + (BOSS_RADIUS if t.has("boss") else 0.4) and (t.has("boss") or _tr(t["elite"])):
				prey = t
				break
		if prey == null and hurt_now:
			for t in candidates:
				if float(t["distance"]) <= ss_range + (BOSS_RADIUS if t.has("boss") else 0.4):
					prey = t
					break
		if prey != null:
			return _action("soul_siphon", prey)
	if can_spend.call("grave_frost"):
		var GF: Dictionary = DmContent.get_export("abilities", "GRAVE_FROST")
		var slope := tan((float(GF["halfAngleDeg"]) * PI) / 180.0)
		var length := float(_ab("grave_frost")["range"])
		var best_f: Variant = null
		var hits_f := 2
		for t in candidates:
			var td: float = t["distance"]
			if td > length or td < 0.01:
				continue
			var dx := (float(t["x"]) - px) / td
			var dz := (float(t["z"]) - pz) / td
			var count := 0
			for j in tn:
				var rx := tx[j] - px
				var rz := tz[j] - pz
				var along := rx * dx + rz * dz
				var er := trd[j]
				if along >= -er and along <= length + er and absf(rx * dz - rz * dx) <= slope * maxf(0.0, along) + er:
					count += 1
			if count > hits_f:
				best_f = t
				hits_f = count
		if best_f != null:
			return _action("grave_frost", best_f)
	if can_spend.call("marrow_spear"):
		var MS: Dictionary = _ab("marrow_spear")
		var best_s: Variant = null
		var hits_s := 1
		for t in candidates:
			var td: float = t["distance"]
			if td > float(MS["range"]) or td < 0.01:
				continue
			var dx := (float(t["x"]) - px) / td
			var dz := (float(t["z"]) - pz) / td
			var count := 0
			for j in tn:
				var rx := tx[j] - px
				var rz := tz[j] - pz
				var along := rx * dx + rz * dz
				if along >= 0.0 and along <= float(MS["range"]) and absf(rx * dz - rz * dx) <= float(MS["radius"]) + trd[j]:
					count += 1
			if count > hits_s:
				best_s = t
				hits_s = count
		if best_s != null:
			return _action("marrow_spear", best_s)
		for t in candidates:
			if float(t["distance"]) <= float(MS["range"]) and essence >= max_essence * (0.6 if t.has("boss") else 0.8):
				return _action("marrow_spear", t)
	if can_spend.call("wailing_skull"):
		# The skull earns its cost on a boss, an elite, or a knot it can leap through.
		var ws_range := float(_ab("wailing_skull")["range"])
		var leap := float(DmContent.get_export("abilities", "WAILING_SKULL")["leapRange"])
		var chain: Variant = null
		for t in candidates:
			if float(t["distance"]) <= ws_range + (BOSS_RADIUS if t.has("boss") else 0.4) and (t.has("boss") or _tr(t["elite"])):
				chain = t
				break
		if chain == null:
			for t in candidates:
				if float(t["distance"]) <= ws_range + (BOSS_RADIUS if t.has("boss") else 0.4) and _around(float(t["x"]), float(t["z"]), leap, tx, tz, trd) >= 3:
					chain = t
					break
		if chain != null:
			return _action("wailing_skull", chain)
	var sig: Variant = ctx.get("signature")
	if _tr(sig) and ready.call(sig) and targets.size() >= 3:
		if sig == "command_rend" and thrall_count >= 2:
			return _action(sig, t0)
		if sig == "plague_bloom" and _around(float(t0["x"]), float(t0["z"]), 4.0, tx, tz, trd) >= 3:
			return _action(sig, t0)
		if sig == "ossuary_wall" and _around(px, pz, 5.0, tx, tz, trd) >= 3:
			return _action(sig, t0)
		if sig == "dirge" and hp_v != null and _tr(max_hp_v) and float(hp_v) < float(max_hp_v) * 0.65:
			return _action(sig, p_pt)
	return _action(primary, needle) if needle != null and ready.call(primary) else null


## How many of the targets (their packed x, z and radius) stand within `radius` plus their own radius of the point (x, z): `_dist(point, t) <= radius + t.radius` for each of them, with
## V8's hypot only where the squares cannot tell (a hair either side of the line; the squares are off by 1e-16 at most, the band is 1e-6).
static func _around(x: float, z: float, radius: float, tx: PackedFloat64Array, tz: PackedFloat64Array, trd: PackedFloat64Array) -> int:
	var n := 0
	for i in tx.size():
		var lim := radius + trd[i]
		if lim < 0.0:
			continue
		var dx := x - tx[i]
		var dz := z - tz[i]
		var d2 := dx * dx + dz * dz
		var l2 := lim * lim
		if d2 < l2 * 0.999999:
			n += 1
		elif d2 <= l2 * 1.000001 and DmSimMath.hypot(dx, dz) <= lim:
			n += 1
	return n


## The candidate that has the most targets within `r` of it (more than `minimum - 1`, the first of equals), among those in `id`'s reach: the knot a cage, a field or a storm wants.
static func _knot(id: String, r: float, minimum: int, candidates: Array, tx: PackedFloat64Array, tz: PackedFloat64Array, trd: PackedFloat64Array) -> Variant:
	var best_k: Variant = null
	var hits_k := minimum - 1
	var reach := float(_ab(id)["range"]) + 0.4
	for i in candidates.size():
		var t: Dictionary = candidates[i]
		if t.has("boss") or float(t["distance"]) > reach:
			continue
		var n := _around(tx[i], tz[i], r, tx, tz, trd)
		if n > hits_k:
			best_k = t
			hits_k = n
	return best_k


## The Reaper (family "reaper", ctx.player.souls = her soul bag): Scythe Sweep is the free filler, souls are spent on the rite that fits the crowd,
## and Wraith Walk is the way out when she is low (away from the nearest foes) or a soul sink to close on a far target when the bag is full.
## Priority: escape, Soul Burst (big crowd or a boss / elite, bag well filled), Reap (a knot in the cone), Harvest Spin (surrounded), Scythe Throw
## (a knot or a boss / elite at range), gap close, Sweep. While hurt she keeps the 4 souls an escape needs.
static func _reaper_action(ctx: Dictionary, targets: Array) -> Variant:
	var p: Variant = ctx["player"]
	var p_pt := {"x": float(_g(p, "x", 0.0)), "z": float(_g(p, "z", 0.0))}
	var souls := int(_g(p, "souls", 0))
	var hp_v: Variant = _g(p, "hp", null)
	var max_hp_v: Variant = _g(p, "maxHp", null)
	var hurt: float = float(hp_v) / float(max_hp_v) if hp_v != null and _tr(max_hp_v) else 1.0
	var ready: Callable = ctx["ready"]
	var nearest: Dictionary = targets[0]
	var nd: float = nearest["distance"]
	var walk_cost := int(_ab("wraith_walk").get("soulCost", 4))
	var reserve := walk_cost if hurt < 0.6 else 0
	var can := func(id: String, keep := 0) -> bool:
		return ready.call(id) and souls >= int(_ab(id).get("soulCost", 0)) + keep
	var tx := PackedFloat64Array()
	var tz := PackedFloat64Array()
	var trd := PackedFloat64Array()
	for t in targets:
		tx.append(t["x"])
		tz.append(t["z"])
		trd.append(t["radius"])
	var crowd := func(centre: Variant, r: float) -> int:
		return _around(float(centre["x"]), float(centre["z"]), r, tx, tz, trd)
	var big := false   # a boss or an elite close enough to be worth spending souls on
	for e in targets:
		if (e.has("boss") or _tr(e.get("elite", false))) and float(e["distance"]) <= 7.0:
			big = true
			break
	# Escape: low on health with foes on her, rush straight away from the nearest one.
	if hurt < 0.35 and nd < 4.5 and can.call("wraith_walk"):
		var ax: float = p_pt["x"] - (float(nearest["x"]) - p_pt["x"]) / maxf(nd, 0.01) * 9.0
		var az: float = p_pt["z"] - (float(nearest["z"]) - p_pt["z"]) / maxf(nd, 0.01) * 9.0
		return {"id": "wraith_walk", "target": {"x": ax, "z": az}}
	var burst_r := float(_ab("soul_burst")["radius"])
	if souls >= 10 and can.call("soul_burst", reserve) \
			and (crowd.call(p_pt, burst_r) >= 5 or (big and souls >= 14) or (souls >= 28 and crowd.call(p_pt, burst_r) >= 2)):
		return {"id": "soul_burst", "target": _aim(p_pt)}
	var reap_r := float(_ab("reap")["range"])
	if can.call("reap", reserve) and nd <= reap_r and (crowd.call(nearest, 3.0) >= 3 or big or souls >= 22):
		return _action("reap", nearest)
	if can.call("harvest_spin", reserve) and crowd.call(p_pt, float(_ab("harvest_spin")["radius"])) >= 3:
		return {"id": "harvest_spin", "target": _aim(p_pt)}
	var throw_r := float(_ab("scythe_throw")["range"])
	if can.call("scythe_throw", reserve) and nd <= throw_r and nd > 3.0:
		var best: Variant = null
		var best_n := 1
		for t in targets:
			if float(t["distance"]) > throw_r:
				continue
			var n: int = crowd.call(t, float(_ab("scythe_throw")["radius"]))
			if n > best_n or (best == null and (t.has("boss") or _tr(t.get("elite", false)))):
				best = t
				best_n = n
		if best != null:
			return _action("scythe_throw", best)
	# A full bag walks to the fight rather than waiting for it.
	if souls >= 24 and nd > 6.0 and nd <= 14.0 and can.call("wraith_walk"):
		return {"id": "wraith_walk", "target": {"x": float(nearest["x"]), "z": float(nearest["z"])}}
	var primary: String = str(ctx.get("primary", "scythe_sweep")) if ctx.get("primary") != null else "scythe_sweep"
	var prim_range: Variant = ctx.get("primaryRange")
	var reach: float = float(prim_range) if prim_range != null else float(_ab(primary)["range"])
	if ready.call(primary) and nd <= reach + float(nearest["radius"]):
		return _action(primary, nearest)
	return null


static func _new_blood_action(ctx: Dictionary, targets: Array) -> Variant:
	var p: Variant = ctx["player"]
	var px := float(_g(p, "x", 0.0))
	var pz := float(_g(p, "z", 0.0))
	var essence := float(_g(p, "essence", 0.0))
	var p_pt := {"x": px, "z": pz}
	var p_area: String = str(_g(p, "area", ""))
	var family: String = ctx["family"]
	var nearest: Dictionary = targets[0]
	var nd: float = nearest["distance"]
	var nearest_boss: bool = nearest.has("boss")
	var nearest_elite: bool = _tr(nearest.get("elite", false))
	var primary: String = str(ctx.get("primary")) if ctx.get("primary") != null else "bone_needle"
	var inready: Callable = ctx["ready"]
	var self_id: Variant = ctx.get("selfId")
	var thrall_count := int(ctx.get("thrallCount", 0))
	var ready := func(id: String) -> bool:
		return inready.call(id) and essence >= float(_ab(id)["essenceCost"])
	var in_range := func(id: String, t: Variant) -> bool:
		return _dist(p_pt, t) <= float(_ab(id)["range"]) + 0.4
	var count := func(t: Variant, r: float) -> int:
		var n := 0
		for e in targets:
			if _dist(t, e) <= r + float(e["radius"]):
				n += 1
		return n
	var real: Array = []
	var echo: Variant = null
	var all_corpses: Array = []
	for c in _list(ctx.get("corpses")):
		all_corpses.append(_corpse(c))
	for c in all_corpses:
		if not _tr(c["echoOwner"]) and (p_area == "" or c["area"] == "" or c["area"] == p_area):
			real.append(c)
	for c in all_corpses:
		if (c["echoOwner"] == "*" or c["echoOwner"] == self_id) and in_range.call("echo", c):
			echo = c
			break
	var body := func(id: String) -> Variant:
		for c in real:
			if in_range.call(id, c):
				return c
		return null
	var hp_v: Variant = _g(p, "hp", null)
	var max_hp_v: Variant = _g(p, "maxHp", null)
	var hurt: float = float(hp_v) / float(max_hp_v) if hp_v != null and _tr(max_hp_v) else 1.0
	var now := float(ctx.get("now", 0.0)) if ctx.get("now") != null else 0.0
	var nstate: String = str(nearest.get("state", ""))
	if family == "warden":
		if hurt < 0.7 and nd <= 12.0 and ready.call("last_light"):
			return _action("last_light", p_pt)
		if nd <= 5.0 and (hurt < 0.75 or int(count.call(p_pt, 5.0)) >= 3) and ready.call("watchmans_ward"):
			return _action("watchmans_ward", p_pt)
		var burning: Variant = null
		for c in real:
			if in_range.call("burn_the_dead", c) and int(count.call(c, 4.0)) >= 2:
				burning = c
				break
		if burning != null and ready.call("burn_the_dead"):
			return _action("burn_the_dead", burning)
		var cremation: Variant = null
		for c in real:
			if in_range.call("cremate", c) and int(count.call(c, 2.0)) >= 1:
				cremation = c
				break
		if cremation != null and ready.call("cremate"):
			return _action("cremate", cremation)
		if nd <= 7.0 and (int(count.call(p_pt, 7.0)) >= 2 or nearest_elite or nearest_boss) and ready.call("lantern_cone"):
			return _action("lantern_cone", nearest)
		if nd > 3.0 and in_range.call("chain_pull", nearest) and ready.call("chain_pull") and not nearest_boss:
			return _action("chain_pull", nearest)
	elif family == "monk":
		if nd <= 9.0 and int(count.call(p_pt, 9.0)) >= 3 and ready.call("great_toll"):
			return _action("great_toll", p_pt)
		if nd <= 4.0 and int(count.call(p_pt, 4.0)) >= 2 and ready.call("choir_of_one"):
			return _action("choir_of_one", p_pt)
		var resonant: Variant = null
		for c in real:
			if in_range.call("sound_the_corpse", c) and int(count.call(c, 3.0)) >= 2 and c["kind"] != "resonant":
				resonant = c
				break
		if resonant != null and ready.call("sound_the_corpse"):
			return _action("sound_the_corpse", resonant)
		var n_max_hp: Variant = nearest.get("maxHp")
		if in_range.call("knell", nearest) and (nearest_elite or nearest_boss or (_tr(n_max_hp) and float(nearest.get("hp", 0.0)) > float(n_max_hp) * 0.7)) and ready.call("knell"):
			return _action("knell", nearest)
		if nd <= 4.0 and (int(count.call(p_pt, 4.0)) >= 2 or nstate == "windup" or nstate == "channel") and ready.call("toll"):
			return _action("toll", p_pt)
		if nd > 2.0 and nd <= 5.0 and ready.call("resonant_step"):
			return _action("resonant_step", nearest)
	elif family == "witch":
		var harvest: Variant = body.call("harvest")
		if harvest != null and essence < 70.0 and ready.call("harvest"):
			return _action("harvest", harvest)
		var charm: Variant = body.call("butcher")
		if charm != null and hurt < 0.65 and ready.call("butcher"):
			return _action("butcher", charm)
		if in_range.call("murder_of_crows", nearest) and int(count.call(nearest, 4.0)) >= 3 and ready.call("murder_of_crows"):
			return _action("murder_of_crows", nearest)
		if in_range.call("hex_charm", nearest) and not nearest_boss and not _tr(nearest.get("hexOwner", "")) and int(count.call(nearest, 4.0)) >= 2 and ready.call("hex_charm"):
			return _action("hex_charm", nearest)
		if in_range.call("crow_swarm", nearest) and int(count.call(nearest, 3.0)) >= 2 and ready.call("crow_swarm"):
			return _action("crow_swarm", nearest)
		if nd > 4.0 and in_range.call("hook_pull", nearest) and ready.call("hook_pull") and not nearest_boss:
			return _action("hook_pull", nearest)
	elif family == "veil":
		if nd <= 6.0 and ready.call("between_worlds") and essence < 45.0:
			return _action("between_worlds", p_pt)
		var pressured: bool = nd <= 5.0 and (hurt < 0.7 or int(count.call(p_pt, 5.0)) >= 3)
		var veil_form: bool = _tr(_g(p, "veilForm", false))
		if pressured and not veil_form and essence >= 45.0 and now >= float(_g(p, "betweenUntil", 0.0)) and ready.call("veil_form"):
			return _action("veil_form", p_pt)
		if veil_form and (essence <= 15.0 or nd > 8.0 or (not pressured and hurt > 0.9)) and ready.call("veil_form"):
			return _action("veil_form", p_pt)
		if echo != null and thrall_count < 5 and ready.call("echo"):
			return _action("echo", echo)
		var rest: Variant = body.call("lay_to_rest")
		if rest != null and (hurt < 0.8 or echo == null) and ready.call("lay_to_rest"):
			return _action("lay_to_rest", rest)
		if in_range.call("veil_tear", nearest) and int(count.call(nearest, 3.0)) >= 2 and ready.call("veil_tear"):
			return _action("veil_tear", nearest)
		if echo != null and nd > 8.0 and _dist(echo, nearest) < 5.0 and ready.call("crossing"):
			return _action("crossing", echo)
	elif family == "knight":
		if hurt < 0.35 and nd <= 8.0 and now >= float(_g(p, "unbreakableUntil", 0.0)) and ready.call("oath_unbroken"):
			return _action("oath_unbroken", p_pt)
		var vigil: Variant = body.call("corpse_vigil")
		if hurt < 0.7 and vigil != null and _dist(p_pt, vigil) <= 2.0 and ready.call("corpse_vigil"):
			return _action("corpse_vigil", vigil)
		if nd <= 3.0 and (hurt < 0.65 or nstate == "windup") and now >= float(_g(p, "bulwarkUntil", 0.0)) and ready.call("bulwark"):
			return _action("bulwark", nearest)
		var brand: Variant = null
		for c in real:
			if in_range.call("grave_brand", c) and int(count.call(c, 1.5)) >= 1:
				brand = c
				break
		if brand != null and ready.call("grave_brand"):
			return _action("grave_brand", brand)
		if in_range.call("grave_slam", nearest) and int(count.call(nearest, 3.0)) >= 2 and ready.call("grave_slam"):
			return _action("grave_slam", nearest)
		if in_range.call("shield_bash", nearest) and nd <= 3.0 and ready.call("shield_bash"):
			return _action("shield_bash", nearest)
	return _action(primary, nearest) if nd <= float(_ab(primary)["range"]) + (BOSS_RADIUS if nearest_boss else 0.4) and ready.call(primary) else null


## Where the primary aims: the nearest target, except pack primaries (Bone Fan) take the densest knot in reach.
static func _primary_target(primary: String, in_reach: Array) -> Variant:
	if in_reach.is_empty():
		return null
	if primary != "bone_fan":
		return in_reach[0]
	var best: Dictionary = in_reach[0]
	var best_n := -1
	for t in in_reach:
		var n := 0
		for o in in_reach:
			if DmSimMath.hypot(float(o["x"]) - float(t["x"]), float(o["z"]) - float(t["z"])) <= 3.0:
				n += 1
		if n > best_n:
			best = t
			best_n = n
	return best


## A local engagement direction. `mem` = AutoMoveMemory Dictionary (mutated) or null. Returns null or {x, z}.
static func select_movement(ctx: Dictionary, mem: Variant = null, now: float = 0.0, dt: float = 0.0) -> Variant:
	var want: Variant = _raw_movement(ctx, mem, now)
	if mem == null:
		return want
	if want == null:
		mem["dir"] = null
		return null
	# Smoothed turning: blend from the last heading instead of snapping (a reversal still turns fast).
	var prev: Variant = (mem as Dictionary).get("dir")
	var out: Dictionary = want
	if prev != null and dt > 0.0:
		var k := 1.0 - DmFdlibmX.exp_(-dt / TURN_SECONDS)
		var x: float = float(prev["x"]) + (float(want["x"]) - float(prev["x"])) * k
		var z: float = float(prev["z"]) + (float(want["z"]) - float(prev["z"])) * k
		var ln := DmSimMath.hypot(x, z)
		out = {"x": x / ln, "z": z / ln} if ln > 0.2 else want
	mem["dir"] = out
	return out


static func _raw_movement(ctx: Dictionary, mem: Variant, now: float) -> Variant:
	var p: Variant = ctx["player"]
	var px := float(_g(p, "x", 0.0))
	var pz := float(_g(p, "z", 0.0))
	var p_pt := {"x": px, "z": pz}
	var p_area: String = str(_g(p, "area", ""))
	var nav: Variant = ctx.get("nav")
	var route_nav: Variant = ctx.get("routeNav", nav)
	# Boss telegraphs, hymn cones and hostile pools come first: step out to the nearest safe spot, and (below) never walk back in.
	var hazards: Variant = ctx.get("hazards")
	var has_goal := false
	if mem != null:
		var dm: Variant = (mem as Dictionary).get("dodge")
		has_goal = dm != null and (dm as Dictionary).get("goal") != null
	if (hazards != null and (hazards as Array).size() > 0) or has_goal:
		var rect: Variant = DmContent.area(p_area)["rect"] if p_area != "" else null
		var dmem: Variant = null
		if mem != null:
			if (mem as Dictionary).get("dodge") == null:
				mem["dodge"] = {}
			dmem = mem["dodge"]
		var dout: Variant = DmAutoDodge.dodge_step(p_pt, hazards if hazards != null else [], dmem, now, {"rect": rect, "nav": nav})
		if dout != null:
			if mem != null:
				mem["evade"] = null  # the ordinary dodge must not resume a stale side
			return dout
	var enemies: Array = []
	for e in _list(ctx.get("enemies")):
		var ed: Dictionary = e if e is Dictionary else _fields(e)
		var v: Variant = ed.get("state")
		var st := "" if v == null else str(v)
		v = ed.get("hp")
		if (0.0 if v == null else float(v)) > 0.0 and st != "dead" and st != "rising" and st != "burrow":
			if p_area != "":
				v = ed.get("area")
				if (("" if v == null else str(v)) != p_area):
					continue
			v = ed.get("x")
			var ex := 0.0 if v == null else float(v)
			v = ed.get("z")
			var ez := 0.0 if v == null else float(v)
			var v_id: Variant = ed.get("id")
			enemies.append({"id": 0 if v_id == null else v_id, "x": ex, "z": ez, "state": st, "distance": DmSimMath.hypot(px - ex, pz - ez)})   # (_dist(p_pt, e))
	enemies = _by_distance(enemies)
	if enemies.is_empty():
		if mem != null:
			mem["targetId"] = null
			mem["closing"] = false
			mem["evade"] = null
		return null
	var nearest: Dictionary = enemies[0]
	# Sticky target: keep the one we were engaging unless another is clearly closer.
	if mem != null and (mem as Dictionary).get("targetId") != null:
		for e in enemies:
			if e["id"] == mem["targetId"]:
				if float(e["distance"]) - float(nearest["distance"]) < STICKY_TARGET_M:
					nearest = e
				break
	if mem != null:
		mem["targetId"] = nearest["id"]
	var d: float = nearest["distance"]
	if d > 36.0 or d < 0.01:
		return null
	var dx := (float(nearest["x"]) - px) / d
	var dz := (float(nearest["z"]) - pz) / d
	var rect2: Variant = DmContent.area(p_area)["rect"] if p_area != "" else null
	var cx := 0.0
	var cz := 0.0
	if rect2 != null:
		cx = (float(rect2["x0"]) + float(rect2["x1"])) / 2.0 - px
		cz = (float(rect2["z0"]) + float(rect2["z1"])) / 2.0 - pz
	var center_d := DmSimMath.hypot(cx, cz)
	if center_d == 0.0:
		center_d = 1.0
	var center := {"x": cx / center_d, "z": cz / center_d}
	var hp_v: Variant = _g(p, "hp", null)
	var max_hp_v: Variant = _g(p, "maxHp", null)
	var low_hp: bool = hp_v != null and _tr(max_hp_v) and float(hp_v) < float(max_hp_v) * 0.32
	if low_hp and d < 5.0:
		return _evade(mem, now, rect2, px, pz, [{"x": -dx, "z": -dz}, {"x": -dz, "z": dx}, {"x": dz, "z": -dx}, center])
	var threatened := false
	for e in enemies:
		if float(e["distance"]) < 4.0 and (e["state"] == "windup" or e["state"] == "channel"):
			threatened = true
			break
	if threatened and d < 3.5:
		return _evade(mem, now, rect2, px, pz, [{"x": -dz, "z": dx}, {"x": dz, "z": -dx}, {"x": -dx, "z": -dz}, center])
	if mem != null and (mem as Dictionary).get("evade") != null and now < float(mem["evade"]["until"]):
		return {"x": float(mem["evade"]["x"]), "z": float(mem["evade"]["z"])}
	if mem != null:
		mem["evade"] = null
	var prim_range: Variant = ctx.get("primaryRange")
	var prim: String = str(ctx.get("primary")) if ctx.get("primary") != null else "bone_needle"
	var reach: float = float(prim_range) if prim_range != null else float(_ab(prim)["range"])
	# Hysteresis: start closing just past reach, keep closing until comfortably inside it.
	var start_at := maxf(1.1, reach - (CLOSE_START if mem != null else 0.4))
	var stop_at := maxf(0.9, reach - CLOSE_STOP)
	var closing: bool = d > stop_at if (mem != null and _tr((mem as Dictionary).get("closing"))) else d > start_at
	if mem != null:
		mem["closing"] = closing
	if closing:
		# A straight line into a tombstone makes the hero grind against it. When the target is out of sight, walk the nav path around.
		if mem != null and route_nav != null:
			if now >= float(_g(mem, "sightAt", 0.0)):
				mem["sightAt"] = now + SIGHT_MS
				mem["blocked"] = now < float(_g(mem, "stuckUntil", 0.0)) or not route_nav.clear_line(px, pz, float(nearest["x"]), float(nearest["z"]), 0.45)
			if _tr((mem as Dictionary).get("blocked")):
				var route: Variant = (mem as Dictionary).get("route")
				if route == null or (route as Array).is_empty() or _g(mem, "routeFor", null) != nearest["id"] or now >= float(_g(mem, "routeAt", 0.0)):
					var path: Array = route_nav.find_path(px, pz, float(nearest["x"]), float(nearest["z"]))
					var conv: Array = []
					for w in path:
						conv.append({"x": float(w[0]), "z": float(w[1])} if w is Array else {"x": float(w["x"]), "z": float(w["z"])})
					mem["route"] = conv
					mem["routeFor"] = nearest["id"]
					mem["routeAt"] = now + ROUTE_MS
				var rt: Array = mem["route"]
				while not rt.is_empty() and DmSimMath.hypot(float(rt[0]["x"]) - px, float(rt[0]["z"]) - pz) < 0.5:
					rt.pop_front()
				if not rt.is_empty():
					var wp: Dictionary = rt[0]
					var l := DmSimMath.hypot(float(wp["x"]) - px, float(wp["z"]) - pz)
					if l == 0.0:
						l = 1.0
					var step := {"x": (float(wp["x"]) - px) / l, "z": (float(wp["z"]) - pz) / l}
					return null if hazards != null and DmAutoDodge.step_into_hazard(p_pt, step, hazards) else step
			else:
				mem["route"] = null
		# Hold here, still attacking, rather than walking into a ring, cone or pool; the way clears when the blow lands.
		var step2: Dictionary = _safe(rect2, px, pz, [{"x": dx, "z": dz}, center])
		return null if hazards != null and DmAutoDodge.step_into_hazard(p_pt, step2, hazards) else step2
	if reach >= 7.0 and d < 3.0:
		var near := 0
		for e in enemies:
			if float(e["distance"]) < 3.5:
				near += 1
		if near >= 2:
			return _evade(mem, now, rect2, px, pz, [{"x": -dx, "z": -dz}, center])
	return null


static func _safe(rect: Variant, px: float, pz: float, choices: Array) -> Dictionary:
	if rect == null:
		return choices[0]
	for v in choices:
		if px + float(v["x"]) * 2.0 > float(rect["x0"]) + 1.0 and px + float(v["x"]) * 2.0 < float(rect["x1"]) - 1.0 \
				and pz + float(v["z"]) * 2.0 > float(rect["z0"]) + 1.0 and pz + float(v["z"]) * 2.0 < float(rect["z1"]) - 1.0:
			return v
	return choices[choices.size() - 1]


## A committed dodge holds its direction briefly so the hero doesn't wobble between sides.
static func _evade(mem: Variant, now: float, rect: Variant, px: float, pz: float, choices: Array) -> Dictionary:
	if mem != null and (mem as Dictionary).get("evade") != null and now < float(mem["evade"]["until"]):
		return {"x": float(mem["evade"]["x"]), "z": float(mem["evade"]["z"])}
	var v: Dictionary = _safe(rect, px, pz, choices)
	if mem != null:
		mem["evade"] = {"x": v["x"], "z": v["z"], "until": now + EVADE_COMMIT_MS}
	return v
