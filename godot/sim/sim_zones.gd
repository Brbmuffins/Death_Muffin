class_name DmSimZones
extends RefCounted
## Zones, corpses, seeds, deaths and the legendary Withered mechanics of WorldSim.ts (static helpers taking the sim).

static func _h(a: float, b: float) -> float:
	return DmSimMath.hypot(a, b)


static func update_zones(sim: DmWorldSim, dt: float) -> void:
	for z: DmSimZone in sim.zones.values():
		if sim.time >= z.until:
			sim.zones.erase(z.id)
			sim.plagueZones.erase(z.id)
			sim.emit({"t": "zoneGone", "id": z.id})
			continue
		z.tick -= dt
		var pulse := z.tick <= 0.0
		if pulse:
			z.tick = 1.0
		if z.creep != 0.0 and z.kind == "miasma":
			creep_zone(sim, z, dt)
		if z.kind == "dirge":
			tick_dirge(sim, z, pulse)
			continue
		if z.kind == "witch_charm":
			var hit: DmSimPlayer = null
			for p: DmSimPlayer in sim.players.values():
				if p.alive and _h(p.x - z.x, p.z - z.z) <= z.r + DmSimConsts.PLAYER_RADIUS:
					hit = p
					break
			if hit != null:
				sim.emit({"t": "newBlood", "by": z.owner, "kind": "heal", "ok": true, "x": hit.x, "z": hit.z, "amount": 0.05, "player": hit.id})
				sim.zones.erase(z.id)
				sim.emit({"t": "zoneGone", "id": z.id})
			continue
		if z.kind == "warden_ward":
			for e: DmSimEnemy in sim.enemies.values():
				if e.state != "dead" and _h(e.x - z.x, e.z - z.z) <= z.r + e.radius:
					e.wardSlowT = maxf(e.wardSlowT, 0.3)
			continue
		if z.kind == "warden_fire" or z.kind == "witch_crows" or z.kind == "veil_rift":
			for e: DmSimEnemy in sim.enemies.values():
				if e.state == "dead" or _h(e.x - z.x, e.z - z.z) > z.r + e.radius:
					continue
				if z.kind == "veil_rift":
					var k := minf(1.0, dt * 2.0)
					var p := sim.nav.resolve_in_area(e.area, e.x + (z.x - e.x) * k, e.z + (z.z - e.z) * k, e.radius)
					e.x = p[0]
					e.z = p[1]
				if pulse:
					sim.damage_enemy(e, z.dps, z.owner)
			continue
		if z.kind == "flower":
			tick_bloom_spread(sim, z, dt)
		if not z.hostile:
			for e: DmSimEnemy in sim.enemies.values():
				if e.state == "dead" or _h(e.x - z.x, e.z - z.z) > z.r + e.radius:
					continue
				e.slowT = 0.3
				if pulse:
					e.withered = minf(z.witheredCap, e.withered + 1.0)
					e.witheredT = 5.0
					e.witheredDps = maxf(e.witheredDps, z.dps)
					e.witheredOwner = z.owner
					if z.contagion:
						e.contagious = true
			var b := sim.boss.state
			if b.active and pulse and _h(b.x - z.x, b.z - z.z) < z.r + DmSimConsts.BOSS_RADIUS:
				b.withered = minf(z.witheredCap, b.withered + 1.0)
				b.witheredT = 5.0
				b.witheredDps = maxf(b.witheredDps, z.dps)
			if z.bloom:
				for c: DmSimCorpse in sim.corpses.values():
					if sim.bloomed.has(c.id) or _h(c.x - z.x, c.z - z.z) > z.r:
						continue
					sim.bloomed[c.id] = true
					sim.remove_corpse(c, "burst", z.owner)
					burst(sim, "bloom", c.x, c.z, 2.6, z.dps * 4.0, z.owner, z.witheredCap)
		elif pulse:
			for p: DmSimPlayer in sim.players.values():
				if p.alive and _h(p.x - z.x, p.z - z.z) < z.r + DmSimConsts.PLAYER_RADIUS:
					sim.emit({"t": "hurt", "player": p.id, "dmg": z.dps, "from": "burn" if z.kind == "ember" else "toxic", "x": z.x, "z": z.z})
			for t: DmSimThrall in sim.thralls.values():
				if _h(t.x - z.x, t.z - z.z) < z.r:
					sim.hurt_thrall(t, z.dps)


## Dirge: mend players and thralls inside each second; enemy casters inside stay Silenced.
static func tick_dirge(sim: DmWorldSim, z: DmSimZone, pulse: bool) -> void:
	var D: Dictionary = DmSimData.SIGNATURE["dirge"]
	for e: DmSimEnemy in sim.enemies.values():
		if e.state != "dead" and _h(e.x - z.x, e.z - z.z) <= z.r + e.radius:
			e.silenceT = float(D["silenceS"])
	if not pulse:
		return
	for p: DmSimPlayer in sim.players.values():
		if p.alive and _h(p.x - z.x, p.z - z.z) <= z.r + DmSimConsts.PLAYER_RADIUS:
			sim.emit({"t": "heal", "player": p.id, "amount": z.dps, "x": p.x, "z": p.z})
	for t: DmSimThrall in sim.thralls.values():
		if t.state != "dead" and _h(t.x - z.x, t.z - z.z) <= z.r:
			t.hp = minf(t.maxHp, t.hp + t.maxHp * float(D["thrallHealFrac"]))


## Plague Bloom: every few seconds a flower seeds the nearest corpse (consuming it) with a new bloom.
static func tick_bloom_spread(sim: DmWorldSim, z: DmSimZone, dt: float) -> void:
	var B: Dictionary = DmSimData.SIGNATURE["bloom"]
	if (z.gen if z.gen >= 0 else 0) >= int(B["maxGenerations"]):
		return
	z.spreadT = (z.spreadT if z.spreadT != INF else float(B["spreadEveryS"])) - dt
	if z.spreadT > 0.0:
		return
	z.spreadT = float(B["spreadEveryS"])
	var best: DmSimCorpse = null
	var best_d := float(B["spreadReach"])
	for c: DmSimCorpse in sim.corpses.values():
		var d := _h(c.x - z.x, c.z - z.z)
		if d > 0.5 and d < best_d:
			best_d = d
			best = c
	if best == null:
		return
	sim.remove_corpse(best, "consumed", z.owner)
	sim.add_zone({"kind": "flower", "owner": z.owner, "x": best.x, "z": best.z, "r": z.r, "durationS": B["childDurationS"], "dps": z.dps, "witheredCap": z.witheredCap, "gen": (z.gen if z.gen >= 0 else 0) + 1})


## Creeping Rot rune: the circle drifts toward the nearest enemy within reach, staying inside its hall.
static func creep_zone(sim: DmWorldSim, z: DmSimZone, dt: float) -> void:
	var best: DmSimEnemy = null
	var best_d := float(DmSimData.RUNE_TUNING["creepingRot"]["seekReach"])
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead" or e.state == "rising" or e.state == "burrow":
			continue
		var d := _h(e.x - z.x, e.z - z.z)
		if d < best_d:
			best_d = d
			best = e
	if best == null or best_d < 0.6:
		return
	var step := minf(z.creep * dt, best_d)
	var nx := z.x + ((best.x - z.x) / best_d) * step
	var nz := z.z + ((best.z - z.z) / best_d) * step
	var area := sim.nav.area_at(z.x, z.z)
	if area != "" and sim.nav.area_at(nx, nz) != area:
		return
	z.x = nx
	z.z = nz


## Contagion rune: a dying enemy that a Contagion circle withered hands its stacks (minus one) to its nearest neighbours.
static func spread_contagion(sim: DmWorldSim, e: DmSimEnemy) -> void:
	var C: Dictionary = DmSimData.RUNE_TUNING["contagion"]
	if not e.contagious or e.withered < float(C["minStacks"]):
		return
	var stacks := e.withered - 1.0
	var cand: Array = []
	for o: DmSimEnemy in sim.enemies.values():
		if o != e and o.state != "dead" and o.hp > 0.0 and o.area == e.area and _h(o.x - e.x, o.z - e.z) <= float(C["reach"]):
			cand.append(o)
	var neighbours: Array = DmStableSort.sorted(cand, func(a: DmSimEnemy, b: DmSimEnemy) -> bool: return _h(a.x - e.x, a.z - e.z) < _h(b.x - e.x, b.z - e.z))
	neighbours = neighbours.slice(0, int(C["neighbours"]))
	for o: DmSimEnemy in neighbours:
		o.withered = maxf(o.withered, stacks)
		o.witheredT = maxf(o.witheredT, 5.0)
		o.witheredDps = maxf(o.witheredDps, e.witheredDps)
		o.witheredOwner = e.witheredOwner
		o.contagious = true
		sim.emit({"t": "contagion", "x": e.x, "z": e.z, "tx": o.x, "tz": o.z, "stacks": stacks})


static func burst(sim: DmWorldSim, kind: String, x: float, z: float, r: float, dmg: float, by: String, withered_cap: float = 5.0) -> void:
	sim.emit({"t": "burst", "kind": kind, "x": x, "z": z, "r": r})
	for e: DmSimEnemy in sim.enemies.values():
		if e.state == "dead" or _h(e.x - x, e.z - z) > r + e.radius:
			continue
		sim.damage_enemy(e, dmg, by)
		if kind == "bloom":
			e.withered = minf(withered_cap, e.withered + 1.0)
			e.witheredT = 5.0


static func clear_seed(sim: DmWorldSim, c: DmSimCorpse) -> void:
	if c.seedOwner == "":
		return
	c.seedOwner = ""
	c.seedDmg = 0.0
	c.seedCap = 0.0
	c.seedArmedAt = INF
	c.seedExpires = 0.0
	sim.emit({"t": "seedGone", "corpseId": c.id})


## Armed seeds burst when a living enemy steps within reach; unarmed ones wither after their life.
static func update_seeds(sim: DmWorldSim) -> void:
	var CS: Dictionary = DmSimData.CARRION_SEED
	for c: DmSimCorpse in sim.corpses.values():
		if c.seedOwner == "":
			continue
		if sim.time >= c.seedExpires:
			clear_seed(sim, c)
			continue
		if sim.time < c.seedArmedAt:
			continue
		var near := false
		for e: DmSimEnemy in sim.enemies.values():
			if e.state == "dead" or e.state == "rising" or e.state == "burrow":
				continue
			if _h(e.x - c.x, e.z - c.z) <= float(CS["triggerR"]) + e.radius:
				near = true
				break
		if not near:
			continue
		var by := c.seedOwner
		var dmg := minf(1e5, c.seedDmg)
		var cap := c.seedCap
		sim.remove_corpse(c, "burst", by)
		var targets := 0
		for e: DmSimEnemy in sim.enemies.values():
			if e.state == "dead" or _h(e.x - c.x, e.z - c.z) > float(CS["burstR"]) + e.radius:
				continue
			sim.damage_enemy(e, dmg, by)
			sim.wither(e, float(CS["withered"]), cap, dmg * float(DmSimData.WITHERED["dpsPerStack"]), by)
			targets += 1
		var b := sim.boss.state
		if b.active and _h(b.x - c.x, b.z - c.z) <= float(CS["burstR"]) + DmSimConsts.BOSS_RADIUS:
			sim.boss.damage(dmg, by, 0.0)
		sim.emit({"t": "seedBurst", "by": by, "x": c.x, "z": c.z, "r": CS["burstR"], "targets": targets})


static func update_corpses(sim: DmWorldSim) -> void:
	update_seeds(sim)
	for c: DmSimCorpse in sim.corpses.values():
		if sim.time >= c.ruptureAt:
			sim.remove_corpse(c, "burst")
			var level := sim.area_level(c.area)
			var zone := DmSimZone.new()
			zone.id = sim.next_id()
			zone.kind = "toxic"
			zone.owner = ""
			zone.x = c.x
			zone.z = c.z
			zone.r = 2.4 * c.scale
			zone.until = sim.time + 5.0
			zone.bornAt = sim.time
			zone.tick = 0.4
			zone.dps = 6.0 * DmEnemyStats.damage_scale(level)
			zone.slow = 1.0
			zone.hostile = true
			sim.zones[zone.id] = zone
			sim.emit({"t": "zone", "zone": zone})
			sim.emit({"t": "burst", "kind": "toxic", "x": c.x, "z": c.z, "r": zone.r})
		elif sim.time >= c.expiresAt:
			sim.remove_corpse(c, "expired")


static func collect_dead(sim: DmWorldSim) -> void:
	for e: DmSimEnemy in sim.enemies.values():
		if e.hp > 0.0 or e.state == "dead":
			continue
		e.state = "dead"
		sim.enemies.erase(e.id)
		sim.dotAccum.erase(e.id)
		if sim.surge != null and sim.surge["ids"].erase(e.id):
			sim.surge["killed"] += 1
		DmSimDirector.depths_kill(sim, e)
		var def: Dictionary = DmSimData.ENEMIES[e.def]
		if e.withered > 0.0 and not sim.legends.is_empty():
			spread_withered(sim, e)
		sim.emit({"t": "death", "id": e.id, "def": e.def, "x": e.x, "z": e.z, "elite": e.elite, "area": e.area, "level": e.level, "killer": e.lastHitBy})
		sim.add_corpse(e.x, e.z, def["corpse"], e.def, e.elite, e.facing, e.scale, e.area)
		if def["corpse"] != "none":
			var veil := false
			for p: DmSimPlayer in sim.players.values():
				if p.alive and p.area == e.area and p.family == "veil":
					veil = true
					break
			if veil:
				var echo := sim.add_corpse(e.x + 0.45, e.z + 0.45, "normal", e.def, false, e.facing, 0.65, e.area)
				if echo != null:
					echo.echoOwner = "*"
					echo.expiresAt = sim.time + 20.0
		spread_contagion(sim, e)
		if e.hexT > 0.0 and e.hexOwner != "":
			var cand: Array = []
			for other: DmSimEnemy in sim.enemies.values():
				if other.state != "dead" and other.area == e.area and _h(other.x - e.x, other.z - e.z) <= 6.0:
					cand.append(other)
			var nb: Array = DmStableSort.sorted(cand, func(a: DmSimEnemy, b: DmSimEnemy) -> bool: return _h(a.x - e.x, a.z - e.z) < _h(b.x - e.x, b.z - e.z))
			nb = nb.slice(0, 2)
			for other: DmSimEnemy in nb:
				other.hexT = maxf(other.hexT, 8.0)
				other.hexOwner = e.hexOwner
		var dc := int(def["deathCorpses"]) if def.has("deathCorpses") else 1
		for k in range(1, dc):
			var a := e.facing + (float(k) / float(dc - 1)) * PI * 2.0
			var p := sim.nav.resolve_in_area(e.area, e.x + DmFdlibm.sin_(a) * 1.6, e.z + DmFdlibm.cos_(a) * 1.6, 0.4)
			sim.add_corpse(p[0], p[1], def["corpse"], "risen", false, a, 1.0, e.area)
		if sim.has_affix(e, "vengeful"):
			DmSimEnemyAI.vengeance(sim, e)
		if DmCombatData.truthy(def.get("emberDeath")):
			var ED: Dictionary = DmSimData.EMBER_DEATH
			sim.ember_pool(e.x, e.z, float(ED["radius"]), float(ED["poolS"]), e.damage * float(ED["poolDpsMult"]))
			sim.emit({"t": "burst", "kind": "ember", "x": e.x, "z": e.z, "r": ED["radius"]})


## Plague Choir 4 (Contagion): an enemy dying inside its stacker's own Miasma passes its Withered stacks to up to LEGEND.spreadMax living enemies within LEGEND.spreadR.
static func spread_withered(sim: DmWorldSim, dead: DmSimEnemy) -> void:
	var owner := dead.witheredOwner
	if owner == "" or not sim.legends.has(owner) or float(sim.legends[owner]["miasmaSpreadsWithered"]) == 0.0:
		return
	var cap := 0.0
	for z: DmSimZone in sim.zones.values():
		if z.hostile or z.kind != "miasma" or z.owner != owner:
			continue
		if _h(dead.x - z.x, dead.z - z.z) <= z.r + dead.radius:
			cap = maxf(cap, z.witheredCap)
	if cap <= 0.0:
		return
	var L: Dictionary = DmSimData.LEGEND
	var cand: Array = []
	for o: DmSimEnemy in sim.enemies.values():
		if o.id != dead.id and o.hp > 0.0 and o.state != "dead" and o.state != "burrow" and o.area == dead.area and _h(o.x - dead.x, o.z - dead.z) <= float(L["spreadR"]):
			cand.append(o)
	var near: Array = DmStableSort.sorted(cand, func(a: DmSimEnemy, b: DmSimEnemy) -> bool: return _h(a.x - dead.x, a.z - dead.z) < _h(b.x - dead.x, b.z - dead.z))
	near = near.slice(0, int(L["spreadMax"]))
	if near.is_empty():
		return
	for o: DmSimEnemy in near:
		o.withered = minf(cap, maxf(o.withered, 0.0) + dead.withered)
		o.witheredT = maxf(o.witheredT, float(DmSimData.WITHERED["durationMs"]) / 1000.0)
		o.witheredDps = maxf(o.witheredDps, dead.witheredDps)
		o.witheredOwner = owner
	sim.emit({"t": "legend", "kind": "spread", "by": owner, "x": dead.x, "z": dead.z, "r": L["spreadR"]})


## Plague Choir 5 (Chain Plague): an enemy whose Withered stacks reach the owner's witheredBurstAt loses them and a fresh Miasma opens on it.
static func update_plague(sim: DmWorldSim) -> void:
	var L: Dictionary = DmSimData.LEGEND
	for e: DmSimEnemy in sim.enemies.values():
		if e.withered <= 0.0 or e.state == "dead" or e.hp <= 0.0:
			continue
		var owner := e.witheredOwner
		var at := 0.0
		if owner != "" and sim.legends.has(owner):
			at = float(sim.legends[owner]["witheredBurstAt"])
		if at <= 0.0 or e.withered < at or sim.time < e.plagueAt:
			continue
		if sim.plagueZones.size() >= int(L["burstClouds"]):
			return
		var last: Variant = sim.lastMiasma.get(owner)
		var r: float = float(last["r"]) if last != null else float(DmSimData.ABILITIES["miasma"]["radius"])
		var dps: float = float(last["dps"]) if last != null else e.witheredDps / float(DmSimData.WITHERED["dpsPerStack"])
		e.plagueAt = sim.time + float(L["burstCdS"])
		e.withered = 0.0
		e.witheredT = 0.0
		e.witheredDps = 0.0
		var zone := DmSimZone.new()
		zone.id = sim.next_id()
		zone.kind = "miasma"
		zone.owner = owner
		zone.x = e.x
		zone.z = e.z
		zone.r = r
		zone.until = sim.time + (float(last["durationMs"]) if last != null else 6000.0) / 1000.0
		zone.bornAt = sim.time
		zone.tick = 0.0
		zone.dps = dps
		zone.slow = DmSimData.MIASMA_SLOW
		zone.witheredCap = maxf(float(last["cap"]) if last != null else 5.0, at)
		zone.bloom = DmCombatData.truthy(last["bloom"]) if last != null else false
		zone.hostile = false
		sim.zones[zone.id] = zone
		sim.plagueZones[zone.id] = true
		sim.emit({"t": "zone", "zone": zone})
		sim.emit({"t": "legend", "kind": "plague", "by": owner, "x": e.x, "z": e.z, "r": r})
