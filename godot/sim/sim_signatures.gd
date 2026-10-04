class_name DmSimSignatures
extends RefCounted
## Host-shaped rites of WorldSim.ts (applySignature + the New Blood families). Static helpers taking the sim.

static func _h(a: float, b: float) -> float:
	return DmSimMath.hypot(a, b)


static func _fin(v: Variant, dflt: float) -> float:
	return float(v) if ((v is float or v is int) and is_finite(float(v))) else dflt


## Walk from (fx, fz) toward (tx, tz) and stop at the last point still inside `area`.
static func last_point_in_area(sim: DmWorldSim, area: String, fx: float, fz: float, tx: float, tz: float) -> Array:
	var n := maxi(1, int(ceilf(_h(tx - fx, tz - fz) / 0.5)))
	var best: Array = [fx, fz]
	for i in range(1, n + 1):
		var x := fx + ((tx - fx) * i) / n
		var z := fz + ((tz - fz) * i) / n
		if sim.nav.area_at(x, z) != area:
			break
		best = [x, z]
	return best


static func strip_shroud(e: DmSimEnemy) -> void:
	if e.affix == "shrouded":
		e.affix = ""
	if not e.extra.is_empty():
		var keep: Array = []
		for x: Dictionary in e.extra:
			if x["affix"] != "shrouded":
				keep.append(x)
		e.extra = keep


static func apply_signature(sim: DmWorldSim, g: Dictionary) -> void:
	var caster: DmSimPlayer = sim.players.get(g["by"])
	var gx := float(g["x"])
	var gz := float(g["z"])
	var clamp_aim := func(rng: float) -> Array:
		if caster == null:
			return [gx, gz]
		var dx := gx - caster.x
		var dz := gz - caster.z
		var d := _h(dx, dz)
		return [gx, gz] if d <= rng else [caster.x + (dx / d) * rng, caster.z + (dz / d) * rng]
	var sp := minf(1e5, maxf(0.0, _fin(g.get("sp"), 0.0)))
	var S: Dictionary = DmSimData.SIGNATURE
	var AB: Dictionary = DmSimData.ABILITIES
	match g["sig"]:
		"wall":
			var W: Dictionary = S["wall"]
			var c: Array = clamp_aim.call(float(W["maxCastRange"]))
			var dx := float(g["dx"])
			var dz := float(g["dz"])
			var dl := _h(dx, dz)
			if not is_finite(dl) or dl < 1e-6:
				dx = 0.0
				dz = -1.0
			else:
				dx = dx / dl
				dz = dz / dl
			var px := -dz * (float(W["length"]) / 2.0)
			var pz := dx * (float(W["length"]) / 2.0)
			var wall := {"id": sim.next_id(), "owner": g["by"], "x0": c[0] - px, "z0": c[1] - pz, "x1": c[0] + px, "z1": c[1] + pz, "until": sim.time + float(W["durationS"])}
			sim.walls[wall["id"]] = wall
			sim.emit({"t": "wall", "id": wall["id"], "owner": g["by"], "x0": wall["x0"], "z0": wall["z0"], "x1": wall["x1"], "z1": wall["z1"], "ms": float(W["durationS"]) * 1000.0})
		"rend":
			var R: Dictionary = S["rend"]
			var a: Array = clamp_aim.call(float(R["maxCastRange"]))
			var c: Array = a
			if caster != null and caster.area != "":
				c = last_point_in_area(sim, caster.area, caster.x, caster.z, a[0], a[1])
			var legion: Array = []
			for t: DmSimThrall in sim.owned_thralls(g["by"]):
				if t.state != "rising":
					legion.append(t)
			var leaps: Array = []
			var hit: Dictionary = {}
			var i := 0
			for t: DmSimThrall in legion:
				var ang := (float(i) / float(maxi(1, legion.size()))) * PI * 2.0
				i += 1
				var p := sim.nav.resolve(c[0] + DmFdlibm.cos_(ang) * 1.2, c[1] + DmFdlibm.sin_(ang) * 1.2, 0.4)
				leaps.append([t.x, t.z, p[0], p[1]])
				t.x = p[0]
				t.z = p[1]
				t.hp = maxf(1.0, t.hp - t.maxHp * float(R["hpCost"]))
				t.attackCd = 0.2
				for e: DmSimEnemy in sim.enemies.values():
					if e.state == "dead" or _h(e.x - p[0], e.z - p[1]) > float(R["cleaveRadius"]) + e.radius:
						continue
					sim.damage_enemy(e, t.damage * float(R["damageMult"]) * sim.cursed_mult(t), g["by"], [t.x, t.z])
					hit[e.id] = true
				var b := sim.boss.state
				if b.active and _h(b.x - p[0], b.z - p[1]) <= float(R["cleaveRadius"]) + DmSimConsts.BOSS_RADIUS:
					sim.boss.damage(t.damage * float(R["damageMult"]) * sim.cursed_mult(t), g["by"], 0.0)
			sim.emit({"t": "rend", "by": g["by"], "x": c[0], "z": c[1], "leaps": leaps, "hits": hit.size()})
		"dirge":
			var D: Dictionary = S["dirge"]
			var c: Array = clamp_aim.call(1.0)
			sim.add_zone({"kind": "dirge", "owner": g["by"], "x": c[0], "z": c[1], "r": D["radius"], "durationS": D["durationS"], "dps": sp * float(AB["dirge"]["power"]), "witheredCap": 0.0})
		"bloom":
			var B: Dictionary = S["bloom"]
			var c: Array = clamp_aim.call(float(B["maxCastRange"]))
			sim.add_zone({"kind": "flower", "owner": g["by"], "x": c[0], "z": c[1], "r": B["radius"], "durationS": B["durationS"], "dps": sp * float(AB["plague_bloom"]["power"]), "witheredCap": B["witheredCap"], "gen": 0})
		"mantle":
			var c: Array = clamp_aim.call(1.0)
			var r := float(AB["bone_mantle"]["radius"])
			var cand: Array = []
			for co: DmSimCorpse in sim.corpses.values():
				if co.echoOwner != "" or (caster != null and caster.area != "" and co.area != caster.area):
					continue
				var d := _h(co.x - c[0], co.z - c[1])
				if d <= r:
					cand.append({"c": co, "d": d})
			var near: Array = DmStableSort.sorted(cand, func(a: Dictionary, b: Dictionary) -> bool: return a["d"] < b["d"])
			near = near.slice(0, int(DmSimData.BONE_MANTLE["maxCorpses"]))
			var tethers: Array = []
			for o: Dictionary in near:
				var co: DmSimCorpse = o["c"]
				tethers.append([co.x, co.z])
				sim.remove_corpse(co, "consumed", g["by"])
			sim.emit({"t": "mantle", "by": g["by"], "x": c[0], "z": c[1], "r": r, "corpses": near.size(), "tethers": tethers})
		"offering":
			var c: Array = clamp_aim.call(float(AB["grave_offering"]["range"]) + 1.0)
			var co := sim.corpse_at(c[0], c[1], float(DmSimData.GRAVE_OFFERING["pickRadius"]), caster.area if caster != null else "")
			if co == null:
				sim.emit({"t": "offering", "by": g["by"], "ok": false, "x": c[0], "z": c[1]})
				return
			sim.remove_corpse(co, "consumed", g["by"])
			sim.emit({"t": "offering", "by": g["by"], "ok": true, "x": co.x, "z": co.z, "corpseKind": co.kind, "elite": co.elite})
		"bash":
			_bash(sim, g, caster, sp)
		"vigil":
			var c: Array = clamp_aim.call(float(AB["corpse_vigil"]["range"]) + 1.0)
			var co := sim.corpse_at(c[0], c[1], float(AB["corpse_vigil"]["radius"]), caster.area if caster != null else "")
			if co == null:
				sim.emit({"t": "vigil", "by": g["by"], "ok": false, "x": c[0], "z": c[1]})
				return
			sim.remove_corpse(co, "consumed", g["by"])
			sim.emit({"t": "vigil", "by": g["by"], "ok": true, "x": co.x, "z": co.z})
		"brand":
			var c: Array = clamp_aim.call(float(AB["grave_brand"]["range"]) + 1.0)
			var co := sim.corpse_at(c[0], c[1], float(AB["grave_brand"]["radius"]), caster.area if caster != null else "")
			if co == null:
				sim.emit({"t": "brand", "by": g["by"], "ok": false, "sprung": false, "x": c[0], "z": c[1]})
				return
			var area := co.area
			var bx := co.x
			var bz := co.z
			sim.remove_corpse(co, "consumed", g["by"])
			sim.brands[sim.next_id()] = {"owner": g["by"], "x": bx, "z": bz, "area": area, "until": sim.time + float(DmSimData.GRAVE_BRAND["lifeS"])}
			sim.emit({"t": "brand", "by": g["by"], "ok": true, "sprung": false, "x": bx, "z": bz})
		"rally":
			var RL: Dictionary = DmSimData.RALLY
			var c: Array = clamp_aim.call(float(AB["rally_dead"]["range"]))
			var secs := minf(float(RL["durationS"]) + float(RL["gravecallerBonusS"]), maxf(float(RL["durationS"]), _fin(g.get("dur"), float(RL["durationS"]))))
			var focus: DmSimEnemy = null
			var best_d := INF
			for e: DmSimEnemy in sim.enemies.values():
				if e.state == "dead" or e.state == "rising" or e.state == "burrow":
					continue
				var d := _h(e.x - c[0], e.z - c[1])
				if d < best_d:
					focus = e
					best_d = d
			var ids: Array = []
			for t: DmSimThrall in sim.owned_thralls(g["by"]):
				t.rallyT = secs
				t.hp = minf(t.maxHp, t.hp + t.maxHp * float(RL["healFrac"]))
				if focus != null and _h(focus.x - t.x, focus.z - t.z) < DmSimConsts.THRALL_LEASH:
					t.target = focus.id
				ids.append(t.id)
			sim.emit({"t": "rally", "by": g["by"], "x": c[0], "z": c[1], "ids": ids})
		"seed":
			var CS: Dictionary = DmSimData.CARRION_SEED
			var c: Array = clamp_aim.call(float(AB["carrion_seed"]["range"]) + 1.0)
			var co := sim.corpse_at(c[0], c[1], float(CS["pickRadius"]), caster.area if caster != null else "")
			if co == null:
				return
			for o: DmSimCorpse in sim.corpses.values():
				if o.seedOwner != g["by"] or o == co:
					continue
				DmSimZones.clear_seed(sim, o)
			co.seedOwner = g["by"]
			co.seedDmg = sp * float(AB["carrion_seed"]["power"])
			co.seedCap = minf(12.0, maxf(1.0, floorf(_fin(g.get("cap"), float(CS["witheredCap"])))))
			co.seedArmedAt = sim.time + float(CS["armS"])
			co.seedExpires = minf(co.expiresAt, sim.time + float(CS["lifeS"]))
			sim.emit({"t": "seeded", "by": g["by"], "corpseId": co.id, "x": co.x, "z": co.z, "armMs": float(CS["armS"]) * 1000.0})
		_:
			_new_blood(sim, g, caster, sp)


static func _bash(sim: DmWorldSim, g: Dictionary, caster: DmSimPlayer, sp: float) -> void:
	var SB: Dictionary = DmSimData.SHIELD_BASH
	var AB: Dictionary = DmSimData.ABILITIES
	var dx := float(g["dx"])
	var dz := float(g["dz"])
	var dl := _h(dx, dz)
	if not is_finite(dl) or dl < 1e-6:
		dx = 0.0
		dz = -1.0
	else:
		dx = dx / dl
		dz = dz / dl
	var ox: float = caster.x if caster != null else float(g["x"])
	var oz: float = caster.z if caster != null else float(g["z"])
	var first: DmSimEnemy = null
	var best_t := INF
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead" or e.state == "rising" or e.state == "burrow":
			continue
		if caster != null and caster.area != "" and e.area != caster.area:
			continue
		var rx := e.x - ox
		var rz := e.z - oz
		var along := rx * dx + rz * dz
		if along < -e.radius or along > float(SB["dashM"]) + e.radius:
			continue
		if absf(rx * -dz + rz * dx) > e.radius + float(AB["shield_bash"]["radius"]):
			continue
		if along < best_t:
			first = e
			best_t = along
	var boss := sim.boss.state
	if caster != null and caster.area == String(DmSimData.BOSSES[sim.bossId]["area"]) and boss.active:
		var rx := boss.x - ox
		var rz := boss.z - oz
		var along := rx * dx + rz * dz
		var across := absf(rx * -dz + rz * dx)
		if along >= -DmSimConsts.BOSS_RADIUS and along <= float(SB["dashM"]) + DmSimConsts.BOSS_RADIUS \
				and across <= DmSimConsts.BOSS_RADIUS + float(AB["shield_bash"]["radius"]) and along < best_t:
			sim.boss.damage(sp * float(AB["shield_bash"]["power"]), g["by"], 0.0)
			sim.boss.stagger(float(SB["bossStunS"]))
			sim.emit({"t": "bash", "by": g["by"], "x": boss.x, "z": boss.z, "id": null})
			return
	if first == null:
		sim.emit({"t": "bash", "by": g["by"], "x": ox + dx * float(SB["dashM"]), "z": oz + dz * float(SB["dashM"]), "id": null})
		return
	sim.damage_enemy(first, sp * float(AB["shield_bash"]["power"]), g["by"])
	first.stunT = maxf(first.stunT, float(SB["stunS"]))
	sim.emit({"t": "bash", "by": g["by"], "x": first.x, "z": first.z, "id": first.id})


## Resolve New Blood corpse, control and area rites on the room host.
static func _new_blood(sim: DmWorldSim, g: Dictionary, caster: DmSimPlayer, sp: float) -> void:
	var gx := float(g["x"])
	var gz := float(g["z"])
	var fail := func(x: float, z: float) -> void:
		sim.emit({"t": "newBlood", "by": g["by"], "kind": g["sig"], "ok": false, "x": x, "z": z})
	if caster == null or not caster.alive or caster.area == "":
		fail.call(gx, gz)
		return
	var def: Variant = DmSimData.ABILITIES.get(g["sig"])
	if def == null:
		fail.call(gx, gz)
		return
	var dx := gx - caster.x
	var dz := gz - caster.z
	var dist := _h(dx, dz)
	var reach: float = float(def["range"]) if (def.has("range") and DmCombatData.truthy(def["range"])) else (float(def["radius"]) if (def.has("radius") and DmCombatData.truthy(def["radius"])) else 1.0)
	var x := caster.x + dx / dist * reach if dist > reach else gx
	var z := caster.z + dz / dist * reach if dist > reach else gz
	var power := float(def["power"]) if def.has("power") else 0.0
	var area := caster.area
	var event := func(amount: Variant = null, target_id: Variant = null, tx: Variant = null, tz: Variant = null) -> void:
		var ev := {"t": "newBlood", "by": g["by"], "kind": g["sig"], "ok": true, "x": x, "z": z}
		if amount != null:
			ev["amount"] = amount
		if target_id != null:
			ev["targetId"] = target_id
		if tx != null:
			ev["tx"] = tx
		if tz != null:
			ev["tz"] = tz
		sim.emit(ev)
	var body := func(r: float = 1.25, echo: bool = false) -> DmSimCorpse:
		var cand: Array = []
		for c: DmSimCorpse in sim.corpses.values():
			var ok: bool
			if echo:
				ok = c.echoOwner != "" and (c.echoOwner == g["by"] or c.echoOwner == "*")
			else:
				ok = c.echoOwner == ""
			if c.area == area and ok and _h(c.x - x, c.z - z) <= r:
				cand.append(c)
		var s: Array = DmStableSort.sorted(cand, func(a: DmSimCorpse, b: DmSimCorpse) -> bool: return _h(a.x - x, a.z - z) < _h(b.x - x, b.z - z))
		return s[0] if not s.is_empty() else null
	var foe := func(rng: float) -> DmSimEnemy:
		var cand: Array = []
		for e: DmSimEnemy in sim.enemies.values():
			if e.state != "dead" and e.state != "rising" and e.state != "burrow" and e.area == area \
					and _h(e.x - x, e.z - z) <= e.radius + 0.8 and _h(e.x - caster.x, e.z - caster.z) <= rng + e.radius:
				cand.append(e)
		var s: Array = DmStableSort.sorted(cand, func(a: DmSimEnemy, b: DmSimEnemy) -> bool: return _h(a.x - x, a.z - z) < _h(b.x - x, b.z - z))
		return s[0] if not s.is_empty() else null
	match g["sig"]:
		"lantern_cone":
			var ln := _h(dx, dz)
			if ln == 0.0:
				ln = 1.0
			for e: DmSimEnemy in sim.enemies.values():
				if e.state == "dead" or e.area != area or _h(e.x - caster.x, e.z - caster.z) > 7.0 + e.radius:
					continue
				var vx := e.x - caster.x
				var vz := e.z - caster.z
				if (vx * dx + vz * dz) / (maxf(0.01, _h(vx, vz)) * ln) < DmFdlibm.cos_(PI / 5.0):
					continue
				strip_shroud(e)
				if e.def == "wraith":
					e.stunT = maxf(e.stunT, 1.5)
			event.call()
		"chain_pull", "hook_pull":
			var e: DmSimEnemy = foe.call(float(def["range"]))
			if e == null:
				fail.call(x, z)
				return
			var p := sim.nav.resolve_in_area(area, caster.x + 0.8, caster.z + 0.8, e.radius)
			e.x = p[0]
			e.z = p[1]
			e.rootT = maxf(e.rootT, 0.25)
			sim.damage_enemy(e, sp * power, g["by"])
			event.call(null, e.id, p[0], p[1])
		"burn_the_dead":
			var cand: Array = []
			for c: DmSimCorpse in sim.corpses.values():
				if c.echoOwner == "" and c.area == area and _h(c.x - x, c.z - z) <= 4.0:
					cand.append(c)
			var bodies: Array = DmStableSort.sorted(cand, func(a: DmSimCorpse, b: DmSimCorpse) -> bool: return _h(a.x - x, a.z - z) < _h(b.x - x, b.z - z))
			bodies = bodies.slice(0, 3)
			if bodies.is_empty():
				fail.call(x, z)
				return
			for c: DmSimCorpse in bodies:
				sim.remove_corpse(c, "consumed", g["by"])
				sim.add_zone({"kind": "warden_fire", "owner": g["by"], "x": c.x, "z": c.z, "r": 1.5, "durationS": 5.0, "dps": sp * power, "witheredCap": 0.0})
			event.call(bodies.size() * 20)
		"watchmans_ward":
			sim.add_zone({"kind": "warden_ward", "owner": g["by"], "x": x, "z": z, "r": 5.0, "durationS": 8.0, "dps": 0.0, "witheredCap": 0.0})
			event.call()
		"cremate":
			var c: DmSimCorpse = body.call()
			if c == null:
				fail.call(x, z)
				return
			sim.remove_corpse(c, "consumed", g["by"])
			sim.add_zone({"kind": "warden_fire", "owner": g["by"], "x": c.x, "z": c.z, "r": 1.5, "durationS": 3.0, "dps": sp * power, "witheredCap": 0.0})
			event.call(20)
		"last_light":
			for e: DmSimEnemy in sim.enemies.values():
				if e.state == "dead" or e.area != area or _h(e.x - caster.x, e.z - caster.z) > 12.0 + e.radius:
					continue
				strip_shroud(e)
				e.stunT = maxf(e.stunT, 1.0)
				sim.damage_enemy(e, sp * power, g["by"])
			for p: DmSimPlayer in sim.players.values():
				if p.alive and p.area == area and _h(p.x - caster.x, p.z - caster.z) <= 12.0:
					sim.emit({"t": "newBlood", "by": g["by"], "kind": "heal", "ok": true, "x": p.x, "z": p.z, "amount": 0.1, "player": p.id})
			event.call()
		"toll", "great_toll":
			var radius := 4.0 if g["sig"] == "toll" else 9.0
			var resonant := false
			for c: DmSimCorpse in sim.corpses.values():
				if c.kind == "resonant" and c.area == area and _h(c.x - caster.x, c.z - caster.z) <= radius:
					resonant = true
					break
			for e: DmSimEnemy in sim.enemies.values():
				if e.state == "dead" or e.area != area or _h(e.x - caster.x, e.z - caster.z) > radius + e.radius:
					continue
				sim.damage_enemy(e, sp * power * (1.5 if resonant else 1.0), g["by"])
				if g["sig"] == "great_toll":
					e.silenceT = maxf(e.silenceT, 3.0)
				else:
					if e.state == "windup" or e.state == "channel":
						e.state = "recover"
					if _fin(g.get("dur"), 0.0) > 0.0:
						e.stunT = maxf(e.stunT, 0.6)
			event.call()
		"resonant_step":
			var sx := caster.x
			var sz := caster.z
			var vx := x - sx
			var vz := z - sz
			var ln := _h(vx, vz)
			if ln == 0.0:
				ln = 1.0
			for e: DmSimEnemy in sim.enemies.values():
				if e.state == "dead" or e.area != area:
					continue
				var ex := e.x - sx
				var ez := e.z - sz
				var along := maxf(0.0, minf(ln, (ex * vx + ez * vz) / ln))
				if _h(ex - vx / ln * along, ez - vz / ln * along) <= e.radius + 0.8:
					sim.damage_enemy(e, sp * power, g["by"])
			event.call()
		"knell":
			var e: DmSimEnemy = foe.call(9.0)
			if e == null:
				fail.call(x, z)
				return
			e.knellBeats = 3.0
			e.knellNext = sim.time + 1.2
			e.knellOwner = g["by"]
			e.knellDamage = sp * power * 1.6
			event.call(null, e.id)
		"sound_the_corpse":
			var c: DmSimCorpse = body.call()
			if c == null:
				fail.call(x, z)
				return
			c.kind = "resonant"
			sim.emit({"t": "corpse", "corpse": c})
			for e: DmSimEnemy in sim.enemies.values():
				if e.state != "dead" and e.area == c.area and _h(e.x - c.x, e.z - c.z) <= 3.0 + e.radius:
					sim.damage_enemy(e, sp * power, g["by"])
			event.call()
		"harvest", "butcher", "lay_to_rest":
			var c: DmSimCorpse = body.call()
			if c == null:
				fail.call(x, z)
				return
			sim.remove_corpse(c, "consumed", g["by"])
			if g["sig"] == "butcher":
				for i in 3:
					var angle := float(i) * PI * 2.0 / 3.0
					sim.add_zone({"kind": "witch_charm", "owner": g["by"], "x": c.x + DmFdlibm.cos_(angle), "z": c.z + DmFdlibm.sin_(angle), "r": 0.65, "durationS": 20.0, "dps": 0.0, "witheredCap": 0.0})
			if g["sig"] == "lay_to_rest":
				for offset in [-0.8, 0.8]:
					var p := sim.nav.resolve_in_area(c.area, c.x + offset, c.z + 0.5, 0.4)
					var echo := sim.add_corpse(p[0], p[1], "normal", c.enemy, false, c.facing, 0.7, c.area)
					if echo != null:
						echo.echoOwner = g["by"]
						echo.expiresAt = sim.time + 20.0
			event.call(30 if g["sig"] == "harvest" else null)
		"crow_swarm":
			sim.add_zone({"kind": "witch_crows", "owner": g["by"], "x": x, "z": z, "r": 3.0, "durationS": 5.0, "dps": sp * power, "witheredCap": 0.0})
			event.call()
		"hex_charm":
			var e: DmSimEnemy = foe.call(9.0)
			if e == null:
				fail.call(x, z)
				return
			e.hexT = 8.0
			e.hexOwner = g["by"]
			event.call(null, e.id)
		"murder_of_crows":
			var existing: DmSimZone = null
			for zn: DmSimZone in sim.zones.values():
				if zn.kind == "witch_crows" and zn.owner == g["by"] and zn.gen == 1:
					existing = zn
					break
			if existing != null:
				existing.x = x
				existing.z = z
				sim.emit({"t": "zone", "zone": existing})
			else:
				sim.add_zone({"kind": "witch_crows", "owner": g["by"], "x": x, "z": z, "r": 4.0, "durationS": 8.0, "dps": sp * power, "witheredCap": 0.0, "gen": 1})
			event.call()
		"echo":
			var c: DmSimCorpse = body.call(1.25, true)
			if c == null:
				fail.call(x, z)
				return
			var owned := sim.owned_thralls(g["by"])
			if owned.size() >= 5:
				var sorted_owned: Array = DmStableSort.sorted(owned, func(a: DmSimThrall, b: DmSimThrall) -> bool: return a.bornAt < b.bornAt)
				sim.kill_thrall(sorted_owned[0], "crumbled")
			sim.remove_corpse(c, "raised", g["by"])
			var WB: Dictionary = DmThralls.base_of("wraith")
			var t := DmSimThrall.new()
			t.id = sim.next_id()
			t.owner = g["by"]
			t.kind = "wraith"
			t.x = c.x
			t.z = c.z
			t.facing = c.facing
			t.hp = 35.0 + sp
			t.maxHp = 35.0 + sp
			t.damage = maxf(5.0, sp * 0.6)
			t.attackInterval = float(WB["interval"])
			t.range = float(WB["range"])
			t.speed = float(WB["speed"])
			t.state = "rising"
			t.stateT = 0.0
			t.attackCd = 0.4
			t.target = -1
			t.slot = owned.size()
			t.bornAt = sim.time
			t.empowered = false
			t.echoUntil = sim.time + 10.0
			sim.thralls[t.id] = t
			sim.emit({"t": "thrall", "id": t.id, "owner": g["by"], "kind": "wraith", "x": t.x, "z": t.z, "empowered": false})
			event.call(null, t.id)
		"veil_tear":
			sim.add_zone({"kind": "veil_rift", "owner": g["by"], "x": x, "z": z, "r": 3.0, "durationS": 2.0, "dps": sp * power, "witheredCap": 0.0})
			event.call()
		"crossing":
			var c: DmSimCorpse = body.call(1.25, true)
			if c == null or _h(c.x - caster.x, c.z - caster.z) > 12.0:
				fail.call(x, z)
				return
			var p := sim.nav.resolve_in_area(c.area, c.x, c.z, 0.45)
			event.call(null, null, p[0], p[1])
		_:
			fail.call(gx, gz)
