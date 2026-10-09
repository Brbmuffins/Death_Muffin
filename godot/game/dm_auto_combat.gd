class_name DmAutoCombat
extends RefCounted
## One-to-one port of archive/legacy-web:src/gameplay/autoCombat.ts (Easy auto's combat decision + movement).
##
## select_action(ctx) = selectAutoCombatAction. ctx keys are the TS AutoCombatInput names:
##   player {x, z, essence, maxEssence, [hp, maxHp, area, veilForm, bulwarkUntil, betweenUntil, unbreakableUntil]},
##   enemies (Array or id->enemy Dictionary of DmSimEnemy / Dictionaries), corpses (same, DmSimCorpse), boss (DmBossState or Dictionary),
##   thrallCount, thrallCap, ready (Callable(id: String) -> bool), [primary, primaryRange, selfId, family, signature, now].
## Returns null or {"id": String, "target": {x, z, [boss: true | enemyId]}}.
## select_movement(ctx, mem, now, dt) = selectAutoCombatMovement: ctx also carries [nav: DmNav, hazards: Array of dm_auto_dodge hazards].
## `mem` is the AutoMoveMemory Dictionary, mutated in place (null = stateless). Returns null or {x, z}.
## Optional TS fields are read through _g(): a missing key, null, or (for sim objects) the field default stands for "undefined".

const BOSS_RADIUS: float = DmSimConsts.BOSS_RADIUS
const STICKY_TARGET_M := 2.0
const CLOSE_START := 0.2
const CLOSE_STOP := 1.1
const EVADE_COMMIT_MS := 450.0
const TURN_SECONDS := 0.1


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


static func _by_distance(arr: Array) -> Array:
	return DmStableSort.sorted(arr, func(a, b): return float(a["distance"]) < float(b["distance"]))


## One Easy-auto combat decision. Returns null or {id, target}.
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
		var hp := float(_g(e, "hp", 0.0))
		var st: String = str(_g(e, "state", ""))
		var e_area: String = str(_g(e, "area", ""))
		if hp <= 0.0 or st == "dead" or st == "rising" or st == "burrow" or (p_area != "" and e_area != "" and e_area != p_area):
			continue
		var d := _dist(p_pt, e)
		if d <= miasma_range:
			targets.append({"x": float(_g(e, "x", 0.0)), "z": float(_g(e, "z", 0.0)), "enemyId": _g(e, "id", 0), "radius": float(_g(e, "radius", 0.5)),
				"distance": d, "elite": _g(e, "elite", false), "hp": hp, "maxHp": _g(e, "maxHp", null), "state": st, "hexOwner": _g(e, "hexOwner", "")})
	targets = _by_distance(targets)
	if targets.size() > 64:
		targets.resize(64)
	if boss != null and bool(_g(boss, "active", false)) and float(_g(boss, "hp", 0.0)) > 0.0 and str(_g(boss, "state", "")) != "dead":
		var bd := _dist(p_pt, boss)
		if bd <= miasma_range:
			targets.append({"x": float(_g(boss, "x", 0.0)), "z": float(_g(boss, "z", 0.0)), "boss": true, "radius": BOSS_RADIUS, "distance": bd})
	if targets.is_empty():
		return null
	targets = _by_distance(targets)
	var family: Variant = ctx.get("family")
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
	inspected = 0
	var exhume_range := float(_ab("exhume")["range"])
	for c in _list(ctx.get("corpses")):
		inspected += 1
		if inspected > 256:
			break
		if str(_g(c, "kind", "normal")) != "none" and _dist(p_pt, c) <= exhume_range:
			corpses.append(_corpse(c))
	corpses = DmStableSort.sorted(corpses, func(a, b): return _dist(p_pt, a) < _dist(p_pt, b))
	if corpses.size() > 32:
		corpses.resize(32)
	if thrall_count < thrall_cap and not corpses.is_empty() and can_spend.call("exhume"):
		return _action("exhume", corpses[0])
	# Grave Offering: only when essence is low AND the legion is full; resonant corpses are kept back for Litany.
	if essence < max_essence * 0.3 and thrall_count >= thrall_cap and ready.call("grave_offering"):
		var go_range := float(_ab("grave_offering")["range"])
		for c in corpses:
			if c["kind"] != "resonant" and not _tr(c["seedOwner"]) and _dist(p_pt, c) <= go_range:
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
			for c in corpses:
				if _tr(c["seedOwner"]):
					continue
				var d := _dist(c, t0)
				if d > 1.5 and d < best_d:
					best = c
					best_d = d
			if best != null:
				return _action("carrion_seed", best)

	var count_around := func(point: Variant, radius: float) -> int:
		var n := 0
		for t in targets:
			if _dist(point, t) <= radius + float(t["radius"]):
				n += 1
		return n
	var hp_v: Variant = _g(p, "hp", null)
	var max_hp_v: Variant = _g(p, "maxHp", null)
	var has_hp: bool = hp_v != null and _tr(max_hp_v)
	# Bone Mantle: armour up when the pack is on you and you are hurt, or when the dead lie thick.
	if can_spend.call("bone_mantle") and count_around.call(p_pt, 3.0) >= 2:
		var hurt: bool = float(hp_v) < float(max_hp_v) * 0.6 if has_hp else false
		var fuel := 0
		var mr := float(_ab("bone_mantle")["radius"])
		for c in corpses:
			if _dist(p_pt, c) <= mr:
				fuel += 1
		if hurt or fuel >= 3:
			return _action("bone_mantle", p_pt)
	# The automatic ritual never destroys the player's army: a large fight with actual corpse fuel only.
	var litany_r := float(_ab("black_litany")["radius"])
	if thrall_count == 0:
		var lc := 0
		for c in corpses:
			if _dist(p_pt, c) <= litany_r:
				lc += 1
		if lc >= 2 and count_around.call(p_pt, litany_r) >= 6 and can_spend.call("black_litany"):
			return _action("black_litany", p_pt)
	if can_spend.call("corpse_explosion"):
		var D: Dictionary = DmContent.get_export("abilities", "DETONATE")
		var best_c: Variant = null
		var hits := 1
		for c in corpses:
			var r := float(D["radius"]) * (float(D["resonantRadiusMult"]) if c["kind"] == "resonant" else 1.0)
			var count: int = count_around.call(c, r)
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
		for t in candidates:
			var count: int = count_around.call(t, float(_ab("miasma")["radius"]))
			if count > hits_m:
				best_m = t
				hits_m = count
		if best_m != null:
			return _action("miasma", best_m)
	# Grimoire expansion: a cage, a field and a storm want a knot of three or more; the siphon wants a sturdy target, or answers pressure.
	var knot := func(id: String, r: float, minimum: int) -> Variant:
		var best_k: Variant = null
		var hits_k := minimum - 1
		for t in candidates:
			if t.has("boss") or float(t["distance"]) > float(_ab(id)["range"]) + 0.4:
				continue
			var n: int = count_around.call(t, r)
			if n > hits_k:
				best_k = t
				hits_k = n
		return best_k
	if can_spend.call("bone_prison"):
		var t: Variant = knot.call("bone_prison", float(_ab("bone_prison")["radius"]), 3)
		if t != null:
			return _action("bone_prison", t)
	if can_spend.call("grave_hands"):
		var t: Variant = knot.call("grave_hands", float(_ab("grave_hands")["radius"]), 3)
		if t != null:
			return _action("grave_hands", t)
	if can_spend.call("bone_storm"):
		var t: Variant = knot.call("bone_storm", float(_ab("bone_storm")["radius"]) + 1.0, 3)
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
			for e in targets:
				var rx := float(e["x"]) - px
				var rz := float(e["z"]) - pz
				var along := rx * dx + rz * dz
				var er := float(e["radius"])
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
			for e in targets:
				var rx := float(e["x"]) - px
				var rz := float(e["z"]) - pz
				var along := rx * dx + rz * dz
				if along >= 0.0 and along <= float(MS["range"]) and absf(rx * dz - rz * dx) <= float(MS["radius"]) + float(e["radius"]):
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
				if float(t["distance"]) <= ws_range + (BOSS_RADIUS if t.has("boss") else 0.4) and int(count_around.call(t, leap)) >= 3:
					chain = t
					break
		if chain != null:
			return _action("wailing_skull", chain)
	var sig: Variant = ctx.get("signature")
	if _tr(sig) and ready.call(sig) and targets.size() >= 3:
		if sig == "command_rend" and thrall_count >= 2:
			return _action(sig, t0)
		if sig == "plague_bloom" and int(count_around.call(t0, 4.0)) >= 3:
			return _action(sig, t0)
		if sig == "ossuary_wall" and int(count_around.call(p_pt, 5.0)) >= 3:
			return _action(sig, t0)
		if sig == "dirge" and hp_v != null and _tr(max_hp_v) and float(hp_v) < float(max_hp_v) * 0.65:
			return _action(sig, p_pt)
	return _action(primary, needle) if needle != null and ready.call(primary) else null


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
		var st: String = str(_g(e, "state", ""))
		if float(_g(e, "hp", 0.0)) > 0.0 and st != "dead" and st != "rising" and st != "burrow" and (p_area == "" or str(_g(e, "area", "")) == p_area):
			enemies.append({"id": _g(e, "id", 0), "x": float(_g(e, "x", 0.0)), "z": float(_g(e, "z", 0.0)), "state": st, "distance": _dist(p_pt, e)})
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
		if mem != null and nav != null:
			if now >= float(_g(mem, "sightAt", 0.0)):
				mem["sightAt"] = now + 200.0
				mem["blocked"] = not nav.clear_line(px, pz, float(nearest["x"]), float(nearest["z"]), 0.45)
			if _tr((mem as Dictionary).get("blocked")):
				var route: Variant = (mem as Dictionary).get("route")
				if route == null or (route as Array).is_empty() or _g(mem, "routeFor", null) != nearest["id"] or now >= float(_g(mem, "routeAt", 0.0)):
					var path: Array = nav.find_path(px, pz, float(nearest["x"]), float(nearest["z"]))
					var conv: Array = []
					for w in path:
						conv.append({"x": float(w[0]), "z": float(w[1])} if w is Array else {"x": float(w["x"]), "z": float(w["z"])})
					mem["route"] = conv
					mem["routeFor"] = nearest["id"]
					mem["routeAt"] = now + 800.0
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
