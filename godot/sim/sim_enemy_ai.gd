class_name DmSimEnemyAI
extends RefCounted
## Enemy AI of WorldSim.ts: targeting, movement, windups and strikes, statuses, elite affixes, Barrow Ghoul burrowing, unbinds.
## Static helpers taking the sim.

static func _h(a: float, b: float) -> float:
	return DmSimMath.hypot(a, b)


static func _tr(d: Dictionary, k: String) -> bool:
	return d.has(k) and DmCombatData.truthy(d[k])


# --- Targeting ---

## Returns {x, z, player: DmSimPlayer|null, thrall: DmSimThrall|null} or null.
static func pick_target(sim: DmWorldSim, e: DmSimEnemy) -> Variant:
	var best: Variant = null
	var best_d: float = DmSimConsts.DEPTHS_AGGRO if e.area == "depths" else DmSimConsts.AGGRO_RANGE
	for p: DmSimPlayer in sim.players.values():
		if not p.alive or p.area != e.area:
			continue
		var d := _h(p.x - e.x, p.z - e.z)
		if d < best_d:
			best_d = d
			best = {"x": p.x, "z": p.z, "player": p, "thrall": null}
	for t: DmSimThrall in sim.thralls.values():
		if t.state == "dead" or t.state == "rising":
			continue
		var d := _h(t.x - e.x, t.z - e.z) * (0.55 if t.kind == "shieldbearer" else 1.1)
		if d < best_d:
			best_d = d
			best = {"x": t.x, "z": t.z, "player": null, "thrall": t}
	return best


## The most wounded unblessed non-Deacon ally within reach.
static func sanctify_target(sim: DmWorldSim, e: DmSimEnemy) -> DmSimEnemy:
	var best: DmSimEnemy = null
	var best_frac := 0.999
	for o: DmSimEnemy in sim.enemies.values():
		if o == e or o.def == "deacon" or o.state == "dead" or o.state == "rising" or o.state == "burrow" or o.sanctT > 0.0:
			continue
		if _h(o.x - e.x, o.z - e.z) > float(DmSimData.SANCTIFIED["range"]):
			continue
		var frac := o.hp / o.maxHp
		if frac < best_frac:
			best_frac = frac
			best = o
	return best


static func frenzied(e: DmSimEnemy) -> bool:
	return _tr(DmSimData.ENEMIES[e.def], "frenzy") and e.hp < e.maxHp * float(DmSimData.FRENZY["atFrac"])


static func move_enemy(sim: DmWorldSim, e: DmSimEnemy, tx: float, tz: float, dt: float, speed_mult: float = 1.0) -> void:
	# Grave Brand roots the feet only: a rooted body still turns and swings.
	if e.rootT > 0.0:
		e.facing = DmFdlibm.atan2_(tx - e.x, tz - e.z)
		return
	if e.area == "depths":
		var hop: Variant = sim.nav.depths_hop(e.x, e.z, tx, tz)
		if hop != null:
			tx = hop["x"]
			tz = hop["z"]
	var dx := tx - e.x
	var dz := tz - e.z
	var d := _h(dx, dz)
	if d < 0.05:
		return
	var slow := minf(DmSimData.MIASMA_SLOW if e.slowT > 0.0 else 1.0, DmSimData.WATCHMANS_WARD_SLOW if e.wardSlowT > 0.0 else 1.0) \
		* (float(DmSimData.CHILL["moveMult"]) if e.chillT > 0.0 else 1.0) * (float(DmSimData.CENSER["moveMult"]) if e.incenseT > 0.0 else 1.0) * (float(DmSimData.FRENZY["moveMult"]) if frenzied(e) else 1.0)
	var step := minf(d, e.speed * speed_mult * slow * dt)
	var px := e.x
	var pz := e.z
	var p := sim.nav.resolve_in_area(e.area, e.x + (dx / d) * step, e.z + (dz / d) * step, e.radius)
	e.x = p[0]
	e.z = p[1]
	if not sim.walls.is_empty():
		var q := sim.push_off_walls(px, pz, e.x, e.z, e.radius)
		e.x = q[0]
		e.z = q[1]
	if e.area == "depths" and step > 1e-3 and ((e.x - px) * dx + (e.z - pz) * dz) / d < step * 0.3:
		var area := e.area
		var rad := e.radius
		var s := sidestep(px, pz, dx / d, dz / d, step, func(x: float, z: float) -> Array: return sim.nav.resolve_in_area(area, x, z, rad))
		e.x = s[0]
		e.z = s[1]
	e.facing = DmFdlibm.atan2_(dx, dz)
	e.moving = true
	e.gait += step * 2.4


## The best of two headings 50 degrees either side of the blocked one, or where the body stood. Returns [x, z].
static func sidestep(px: float, pz: float, ux: float, uz: float, step: float, resolve: Callable) -> Array:
	var best: Array = [px, pz]
	var best_gain := 0.0
	for a in [0.87, -0.87]:
		var c := DmFdlibm.cos_(a)
		var s := DmFdlibm.sin_(a)
		var n: Array = resolve.call(px + (ux * c - uz * s) * step, pz + (ux * s + uz * c) * step)
		var gain: float = (n[0] - px) * ux + (n[1] - pz) * uz + _h(n[0] - px, n[1] - pz) * 0.5
		if gain > best_gain:
			best_gain = gain
			best = n
	return best


## Where a Bog Hag lays her hex: the centre of the thrall standing in the thickest knot within reach; the target itself if none.
static func hex_aim(sim: DmWorldSim, e: DmSimEnemy, target: Dictionary) -> Array:
	var reach := float(DmSimData.ENEMIES[e.def]["attackRange"])
	var best: DmSimThrall = null
	var best_n := 0
	for t: DmSimThrall in sim.thralls.values():
		if t.state == "dead" or t.state == "rising" or _h(t.x - e.x, t.z - e.z) > reach:
			continue
		var n := 0
		for o: DmSimThrall in sim.thralls.values():
			if o.state != "dead" and _h(o.x - t.x, o.z - t.z) <= float(DmSimData.HAG_HEX["radius"]):
				n += 1
		if n > best_n:
			best_n = n
			best = t
	return [best.x, best.z] if best != null else [target["x"], target["z"]]


# --- Strikes ---

static func strike(sim: DmWorldSim, e: DmSimEnemy, kind: String, slam_r: float = -1.0) -> void:
	var def: Dictionary = DmSimData.ENEMIES[e.def]
	if kind == "hex":
		var H: Dictionary = DmSimData.HAG_HEX
		for p: DmSimPlayer in sim.players.values():
			if p.alive and _h(p.x - e.aimX, p.z - e.aimZ) <= float(H["radius"]):
				sim.emit({"t": "hurt", "player": p.id, "dmg": sim.blow(e) * float(H["blowMult"]), "from": "curse", "x": e.x, "z": e.z, "chillMs": H["chillMs"]})
		for t: DmSimThrall in sim.thralls.values():
			if _h(t.x - e.aimX, t.z - e.aimZ) > float(H["radius"]):
				continue
			sim.hurt_thrall(t, sim.blow(e) * float(H["blowMult"]))
			if t.hp > 0.0:
				t.cursedT = float(H["durationS"])
		return
	if kind == "pulse":
		var W: Dictionary = DmSimData.WISP_PULSE
		for p: DmSimPlayer in sim.players.values():
			if p.alive and _h(p.x - e.aimX, p.z - e.aimZ) <= float(W["radius"]):
				sim.emit({"t": "hurt", "player": p.id, "dmg": sim.blow(e), "from": "dust", "x": e.x, "z": e.z, "chillMs": W["chillMs"]})
		for t: DmSimThrall in sim.thralls.values():
			if _h(t.x - e.aimX, t.z - e.aimZ) <= float(W["radius"]):
				sim.hurt_thrall(t, sim.blow(e))
		return
	if kind == "hook":
		var SH: Dictionary = DmSimData.SEXTON_HOOK
		var dx := e.aimX - e.x
		var dz := e.aimZ - e.z
		var ln := _h(dx, dz)
		if ln == 0.0:
			ln = 1.0
		var ux := dx / ln
		var uz := dz / ln
		var on_line := func(x: float, z: float) -> bool:
			var along := (x - e.x) * ux + (z - e.z) * uz
			if along < 0.0 or along > float(SH["range"]) + 0.6:
				return false
			return absf((x - e.x) * uz - (z - e.z) * ux) <= float(SH["halfWidth"]) + 0.3 and not sim.wall_between(e.x, e.z, x, z)
		for p: DmSimPlayer in sim.players.values():
			if p.alive and on_line.call(p.x, p.z):
				sim.emit({"t": "hurt", "player": p.id, "dmg": sim.blow(e) * float(SH["blowMult"]), "from": "melee", "x": e.x, "z": e.z, "pull": {"x": e.x, "z": e.z, "m": SH["pullM"], "rootMs": SH["rootMs"]}})
		for t: DmSimThrall in sim.thralls.values():
			if on_line.call(t.x, t.z):
				sim.hurt_thrall(t, sim.blow(e) * float(SH["blowMult"]))
		sim.emit({"t": "melee", "id": e.id, "x": e.x, "z": e.z, "tx": e.aimX, "tz": e.aimZ})
		return
	if kind == "ember":
		var EB: Dictionary = DmSimData.EMBER_BOLT
		for p: DmSimPlayer in sim.players.values():
			if p.alive and _h(p.x - e.aimX, p.z - e.aimZ) <= float(EB["radius"]):
				sim.emit({"t": "hurt", "player": p.id, "dmg": sim.blow(e), "from": "ember", "x": e.x, "z": e.z})
		for t: DmSimThrall in sim.thralls.values():
			if _h(t.x - e.aimX, t.z - e.aimZ) <= float(EB["radius"]):
				sim.hurt_thrall(t, sim.blow(e))
		sim.ember_pool(e.aimX, e.aimZ, float(EB["radius"]), float(EB["poolS"]), sim.blow(e) * float(EB["poolDpsMult"]))
		return
	if kind == "flask":
		var PF: Dictionary = DmSimData.PLAGUE_FLASK
		for p: DmSimPlayer in sim.players.values():
			if p.alive and _h(p.x - e.aimX, p.z - e.aimZ) <= float(PF["radius"]):
				sim.emit({"t": "hurt", "player": p.id, "dmg": sim.blow(e), "from": "toxic", "x": e.x, "z": e.z})
		for t: DmSimThrall in sim.thralls.values():
			if _h(t.x - e.aimX, t.z - e.aimZ) <= float(PF["radius"]):
				sim.hurt_thrall(t, sim.blow(e))
		var zone := DmSimZone.new()
		zone.id = sim.next_id()
		zone.kind = "toxic"
		zone.owner = ""
		zone.x = e.aimX
		zone.z = e.aimZ
		zone.r = float(PF["radius"])
		zone.until = sim.time + float(PF["poolS"])
		zone.bornAt = sim.time
		zone.tick = 1.0
		zone.dps = sim.blow(e) * float(PF["poolDpsMult"])
		zone.slow = 1.0
		zone.hostile = true
		sim.zones[zone.id] = zone
		sim.emit({"t": "zone", "zone": zone})
		sim.emit({"t": "burst", "kind": "toxic", "x": e.aimX, "z": e.aimZ, "r": PF["radius"]})
		return
	if kind == "dust":
		var DU: Dictionary = DmSimData.DUST
		for p: DmSimPlayer in sim.players.values():
			if p.alive and _h(p.x - e.aimX, p.z - e.aimZ) <= float(DU["radius"]):
				sim.emit({"t": "hurt", "player": p.id, "dmg": sim.blow(e), "from": "dust", "x": e.x, "z": e.z})
		for t: DmSimThrall in sim.thralls.values():
			if _h(t.x - e.aimX, t.z - e.aimZ) <= float(DU["radius"]):
				sim.hurt_thrall(t, sim.blow(e))
		var zone := DmSimZone.new()
		zone.id = sim.next_id()
		zone.kind = "dust"
		zone.owner = ""
		zone.x = e.aimX
		zone.z = e.aimZ
		zone.r = float(DU["radius"])
		zone.until = sim.time + float(DU["cloudS"])
		zone.bornAt = sim.time
		zone.tick = 1.0
		zone.dps = sim.blow(e) * float(DU["cloudDpsMult"])
		zone.slow = 1.0
		zone.hostile = true
		sim.zones[zone.id] = zone
		sim.emit({"t": "zone", "zone": zone})
		return
	if kind == "scream":
		var SC: Dictionary = DmSimData.SCREAM
		for p: DmSimPlayer in sim.players.values():
			if p.alive and _h(p.x - e.aimX, p.z - e.aimZ) <= float(SC["radius"]):
				sim.emit({"t": "hurt", "player": p.id, "dmg": sim.blow(e), "from": "scream", "x": e.x, "z": e.z})
		for t: DmSimThrall in sim.thralls.values():
			if _h(t.x - e.aimX, t.z - e.aimZ) <= float(SC["radius"]):
				sim.hurt_thrall(t, sim.blow(e))
		return
	if kind == "cone":
		var dir_x := e.aimX - e.x
		var dir_z := e.aimZ - e.z
		var ln := _h(dir_x, dir_z)
		if ln == 0.0:
			ln = 1.0
		var hits := func(x: float, z: float) -> bool:
			var vx := x - e.x
			var vz := z - e.z
			var d := _h(vx, vz)
			if d > float(def["attackRange"]) + DmSimConsts.CONE_REACH_PAD:
				return false
			if sim.wall_between(e.x, e.z, x, z):
				return false
			var den := d * ln
			if den == 0.0:
				den = 1.0
			return (vx * dir_x + vz * dir_z) / den > DmFdlibm.cos_((30.0 * PI) / 180.0)
		for p: DmSimPlayer in sim.players.values():
			if p.alive and hits.call(p.x, p.z):
				sim.emit({"t": "hurt", "player": p.id, "dmg": sim.blow(e), "from": "cone", "x": e.x, "z": e.z})
		for t: DmSimThrall in sim.thralls.values():
			if hits.call(t.x, t.z):
				sim.hurt_thrall(t, sim.blow(e))
		return
	var reach: float
	if kind == "slam":
		reach = slam_r if slam_r >= 0.0 else (float(def["slamRadius"]) if _tr(def, "slamRadius") else 1.9)
	else:
		reach = float(def["attackRange"]) * 1.35 + 0.4
	var cx := e.aimX if kind == "slam" else e.x
	var cz := e.aimZ if kind == "slam" else e.z
	var p: DmSimPlayer = sim.players.get(e.targetPlayer) if e.targetPlayer != "" else null
	if p != null and p.alive and _h(p.x - cx, p.z - cz) <= reach:
		var from := "melee"
		if kind == "curse":
			from = "curse"
		elif _tr(def, "rotBite"):
			from = "toxic"
		sim.emit({"t": "hurt", "player": p.id, "dmg": sim.blow(e), "from": from, "x": e.x, "z": e.z})
	var t: DmSimThrall = sim.thralls.get(e.targetThrall) if e.targetThrall >= 0 else null
	if t != null and _h(t.x - cx, t.z - cz) <= reach:
		sim.hurt_thrall(t, sim.blow(e))
	if kind == "slam":
		for other: DmSimPlayer in sim.players.values():
			if other != p and other.alive and _h(other.x - cx, other.z - cz) <= reach:
				sim.emit({"t": "hurt", "player": other.id, "dmg": sim.blow(e), "from": "melee", "x": e.x, "z": e.z})
	sim.emit({"t": "melee", "id": e.id, "x": e.x, "z": e.z, "tx": cx, "tz": cz})


# --- Statuses ---

static func tick_statuses(sim: DmWorldSim, e: DmSimEnemy, dt: float) -> void:
	if e.knellBeats > 0.0 and sim.time >= e.knellNext:
		e.knellNext = sim.time + 1.2
		e.knellBeats -= 1.0
		sim.damage_enemy(e, maxf(1.0, e.knellDamage), e.knellOwner)
	e.flash = maxf(0.0, e.flash - dt * 8.0)
	if e.markT > 0.0:
		e.markT -= dt
	if e.slowT > 0.0:
		e.slowT -= dt
	if e.wardSlowT > 0.0:
		e.wardSlowT -= dt
	if e.fractureT > 0.0:
		e.fractureT -= dt
		if e.fractureT <= 0.0:
			e.fracture = 0.0
	if e.chillT > 0.0:
		e.chillT -= dt
	if e.sanctT > 0.0:
		e.sanctT -= dt
	if e.hexT > 0.0:
		e.hexT -= dt
	if e.silenceT > 0.0:
		e.silenceT -= dt
	if e.stunT > 0.0:
		e.stunT -= dt
	if e.rootT > 0.0:
		e.rootT -= dt
	if e.incenseT > 0.0:
		e.incenseT -= dt
	if e.unbindCd > 0.0:
		e.unbindCd -= dt
	var underground := e.state == "burrow" or (e.erupting != null and e.state == "windup")
	if e.bleedT > 0.0 and e.bleedDps > 0.0:
		e.bleedT -= dt
		var dmg := 0.0 if underground else e.bleedDps * dt * sim.damage_taken_mult(e)
		e.hp -= dmg
		e.lastHitBy = e.bleedOwner if e.bleedOwner != "" else e.lastHitBy
		var acc: float = float(sim.dotAccum.get(e.id, 0.0)) + dmg
		if acc >= maxf(4.0, e.maxHp * 0.06):
			sim.emit({"t": "dmg", "x": e.x, "z": e.z, "amount": DmMath.js_round(acc), "kind": "dot", "by": e.bleedOwner})
			sim.dotAccum[e.id] = 0.0
		else:
			sim.dotAccum[e.id] = acc
		if e.bleedT <= 0.0:
			e.bleedDps = 0.0
	if e.witheredT > 0.0 and e.withered > 0.0:
		e.witheredT -= dt
		var dmg := 0.0 if underground else e.withered * e.witheredDps * dt * sim.damage_taken_mult(e)
		e.hp -= dmg
		e.lastHitBy = e.witheredOwner if e.witheredOwner != "" else e.lastHitBy
		var acc: float = float(sim.dotAccum.get(e.id, 0.0)) + dmg
		if acc >= maxf(4.0, e.maxHp * 0.06):
			sim.emit({"t": "dmg", "x": e.x, "z": e.z, "amount": DmMath.js_round(acc), "kind": "dot", "by": e.witheredOwner})
			sim.dotAccum[e.id] = 0.0
		else:
			sim.dotAccum[e.id] = acc
		if e.witheredT <= 0.0:
			e.withered = 0.0
			e.witheredDps = 0.0


# --- The per-tick enemy loop ---

static func update_enemies(sim: DmWorldSim, dt: float) -> void:
	var active_areas: Dictionary = {}
	for p: DmSimPlayer in sim.players.values():
		if p.alive and p.area != "":
			active_areas[p.area] = true
	tick_unbinds(sim)
	# A JS Map iteration also visits entries added while it runs (a Deacon raising a Risen mid-loop): emulate it by ascending id.
	var seen_max := 0
	var keys: Array = sim.enemies.keys()
	var idx := 0
	while true:
		if idx >= keys.size():
			var more: Array = []
			for k in sim.enemies.keys():
				if k > seen_max:
					more.append(k)
			if more.is_empty():
				break
			keys = more
			idx = 0
		var id: int = keys[idx]
		idx += 1
		if id > seen_max:
			seen_max = id
		var e: DmSimEnemy = sim.enemies.get(id)
		if e == null:
			continue
		_update_one(sim, e, dt, active_areas)


static func _update_one(sim: DmWorldSim, e: DmSimEnemy, dt: float, active_areas: Dictionary) -> void:
	e.moving = false
	tick_statuses(sim, e, dt)
	e.stateT += dt
	if e.state == "rising":
		if e.stateT >= DmSimConsts.RISE_TIME:
			e.state = "move"
			e.stateT = 0.0
		return
	if not active_areas.has(e.area):
		return
	if e.state == "burrow":
		tick_burrow(sim, e, dt)
		return
	var def: Dictionary = DmSimData.ENEMIES[e.def]
	if _tr(def, "inert"):
		return
	if e.stunT > 0.0:
		if e.state == "windup" or e.state == "channel":
			e.state = "recover"
			e.stateT = 0.0
			e.channelCorpse = -1
			if e.diving:
				end_dive(sim, e)
			if e.erupting != null:
				e.erupting = null
				e.state = "burrow"
		return
	if e.affix != "":
		tick_affix(sim, e, dt)
	if e.hookCd > 0.0:
		e.hookCd -= dt
	e.attackCd -= dt * (float(DmSimData.CHILL["attackRateMult"]) if e.chillT > 0.0 else 1.0) * (float(DmSimData.CENSER["attackRateMult"]) if e.incenseT > 0.0 else 1.0) * (float(DmSimData.FRENZY["attackRateMult"]) if frenzied(e) else 1.0)
	var wms := float(def["windupMs"]) * (0.85 if e.elite else 1.0)
	if _tr(def, "aura"):
		censer_pulse(sim, e, dt)

	if e.state == "windup" or e.state == "channel":
		var windup: float
		if e.erupting != null and e.state == "windup":
			windup = erupt_ms(e) / 1000.0
		else:
			windup = (1.5 if e.state == "channel" else float(def["windupMs"]) / 1000.0) * (0.85 if e.elite else 1.0)
		if e.diving:
			var k := maxf(0.0, minf(1.0, (e.stateT - windup * 0.5) / (windup * 0.5)))
			var ease_ := k * k
			e.x = e.diveX + (e.aimX - e.diveX) * ease_
			e.z = e.diveZ + (e.aimZ - e.diveZ) * ease_
		if e.stateT >= windup:
			release(sim, e)
		return
	if e.state == "recover":
		if e.stateT >= 0.3 + e.groundT:
			e.state = "move"
			e.stateT = 0.0
			e.groundT = 0.0
			if e.digPending:
				e.digPending = false
				e.state = "burrow"
				e.burrowLeft = float(DmSimData.BURROW["travelM"])
				e.bleedT = 0.0
				e.bleedDps = 0.0
				e.withered = 0.0
				e.witheredT = 0.0
				e.rootT = 0.0
				e.slowT = 0.0
				e.chillT = 0.0
		return

	var silenced := e.silenceT > 0.0
	if _tr(def, "ward") and e.attackCd <= 0.0 and not silenced:
		seraph_ward(sim, e)
	if def["behavior"] == "support" and not _tr(def, "ward") and e.attackCd <= 0.0 and not silenced:
		var corpse := sim.nearest_corpse(e.x, e.z, 8.0)
		if corpse != null:
			e.state = "channel"
			e.stateT = 0.0
			e.channelCorpse = corpse.id
			e.aimX = corpse.x
			e.aimZ = corpse.z
			sim.emit({"t": "telegraph", "id": e.id, "kind": "raise", "x": e.x, "z": e.z, "tx": corpse.x, "tz": corpse.z, "ms": 1500.0 * (0.85 if e.elite else 1.0)})
			return
		var ally := sanctify_target(sim, e)
		if ally != null:
			ally.sanctT = float(DmSimData.SANCTIFIED["durationS"])
			e.attackCd = (float(def["cooldownMs"]) / 1000.0) * float(DmSimData.SANCTIFIED["cooldownMult"])
			sim.emit({"t": "sanctify", "id": e.id, "target": ally.id, "x": e.x, "z": e.z, "tx": ally.x, "tz": ally.z})

	var target: Variant = pick_target(sim, e)
	e.targetPlayer = target["player"].id if (target != null and target["player"] != null) else ""
	e.targetThrall = target["thrall"].id if (target != null and target["thrall"] != null) else -1
	if target == null:
		if sim.rand() < dt * 0.3:
			e.facing += (sim.rand() - 0.5) * 2.0
		move_enemy(sim, e, e.x + DmFdlibm.sin_(e.facing), e.z + DmFdlibm.cos_(e.facing), dt, 0.3)
		return
	var tgx: float = target["x"]
	var tgz: float = target["z"]
	var dist := _h(tgx - e.x, tgz - e.z)
	if e.area == "depths" and sim.nav.depths_hop(e.x, e.z, tgx, tgz) != null:
		move_enemy(sim, e, tgx, tgz, dt)
		return

	match def["behavior"]:
		"melee", "hazard", "flank":
			if e.fleeT > 0.0:
				e.fleeT -= dt
				var px := -(tgz - e.z) / (dist if dist != 0.0 else 1.0)
				var pz := (tgx - e.x) / (dist if dist != 0.0 else 1.0)
				move_enemy(sim, e, e.x * 2.0 - tgx + px * 2.0 * e.flankSide, e.z * 2.0 - tgz + pz * 2.0 * e.flankSide, dt)
				return
			var SH: Dictionary = DmSimData.SEXTON_HOOK
			if _tr(def, "hook") and target["player"] != null and e.attackCd <= 0.0 and e.hookCd <= 0.0 and dist >= float(SH["minRange"]) and dist <= float(SH["range"]) and not sim.wall_between(e.x, e.z, tgx, tgz):
				e.state = "windup"
				e.stateT = 0.0
				e.hooking = true
				e.hookCd = float(SH["cooldownS"])
				e.aimX = tgx
				e.aimZ = tgz
				e.facing = DmFdlibm.atan2_(tgx - e.x, tgz - e.z)
				sim.emit({"t": "telegraph", "id": e.id, "kind": "hook", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms, "r": SH["range"]})
				return
			if _tr(def, "dive") and e.attackCd <= 0.0 and dist >= float(def["dive"]["minRange"]) and dist <= float(def["dive"]["range"]) and not sim.wall_between(e.x, e.z, tgx, tgz):
				e.state = "windup"
				e.stateT = 0.0
				e.diving = true
				e.diveX = e.x
				e.diveZ = e.z
				e.aimX = tgx
				e.aimZ = tgz
				e.facing = DmFdlibm.atan2_(tgx - e.x, tgz - e.z)
				sim.emit({"t": "telegraph", "id": e.id, "kind": "dive", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms, "r": def["dive"]["radius"]})
				return
			if dist <= float(def["attackRange"]) + 0.35 and e.attackCd <= 0.0:
				e.state = "windup"
				e.stateT = 0.0
				e.aimX = tgx
				e.aimZ = tgz
				e.facing = DmFdlibm.atan2_(tgx - e.x, tgz - e.z)
				if def["behavior"] == "hazard":
					var ev := {"t": "telegraph", "id": e.id, "kind": "slam", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms}
					if _tr(def, "slamRadius"):
						ev["r"] = def["slamRadius"]
					sim.emit(ev)
			elif dist > float(def["attackRange"]) * 0.8:
				var tx := tgx
				var tz := tgz
				if def["behavior"] == "flank" and dist > 2.5:
					var px := -(tgz - e.z) / dist
					var pz := (tgx - e.x) / dist
					var off := minf(3.0, dist * 0.45) * e.flankSide
					tx += px * off
					tz += pz * off
				move_enemy(sim, e, tx, tz, dt)
		"caster":
			var atk: String = def.get("attack", "cone")
			if dist <= float(def["attackRange"]) - 0.5 and e.attackCd <= 0.0 and not silenced:
				e.state = "windup"
				e.stateT = 0.0
				e.aimX = tgx
				e.aimZ = tgz
				e.facing = DmFdlibm.atan2_(tgx - e.x, tgz - e.z)
				if atk == "hex":
					var ha := hex_aim(sim, e, target)
					e.aimX = ha[0]
					e.aimZ = ha[1]
					e.facing = DmFdlibm.atan2_(ha[0] - e.x, ha[1] - e.z)
					sim.emit({"t": "telegraph", "id": e.id, "kind": "hex", "x": e.x, "z": e.z, "tx": ha[0], "tz": ha[1], "ms": wms, "r": DmSimData.HAG_HEX["radius"]})
				elif atk == "pulse":
					sim.emit({"t": "telegraph", "id": e.id, "kind": "pulse", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms, "r": DmSimData.WISP_PULSE["radius"]})
				elif atk == "scream":
					sim.emit({"t": "telegraph", "id": e.id, "kind": "scream", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms, "r": DmSimData.SCREAM["radius"]})
				elif atk == "dust":
					sim.emit({"t": "telegraph", "id": e.id, "kind": "dust", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms, "r": DmSimData.DUST["radius"]})
				elif atk == "flask":
					sim.emit({"t": "telegraph", "id": e.id, "kind": "flask", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms, "r": DmSimData.PLAGUE_FLASK["radius"]})
				elif atk == "ember":
					sim.emit({"t": "telegraph", "id": e.id, "kind": "ember", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms, "r": DmSimData.EMBER_BOLT["radius"]})
				elif atk == "curse":
					sim.emit({"t": "telegraph", "id": e.id, "kind": "curse", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms})
				else:
					sim.emit({"t": "telegraph", "id": e.id, "kind": "cone", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms})
			elif dist > float(def["attackRange"]) - 1.5:
				move_enemy(sim, e, tgx, tgz, dt)
			elif dist < 3.5:
				var rx := e.x * 2.0 - tgx
				var rz := e.z * 2.0 - tgz
				if _tr(def, "lure"):
					var dd := dist if dist != 0.0 else 1.0
					var ax := (e.x - tgx) / dd
					var az := (e.z - tgz) / dd
					var lx: float = float(DmSimData.FEN_LURE["x"]) - e.x
					var lz: float = float(DmSimData.FEN_LURE["z"]) - e.z
					var ll := _h(lx, lz)
					if ll == 0.0:
						ll = 1.0
					rx = e.x + (ax * 0.55 + (lx / ll) * 0.45) * 3.0
					rz = e.z + (az * 0.55 + (lz / ll) * 0.45) * 3.0
				move_enemy(sim, e, rx, rz, dt, 0.8)
			else:
				e.facing = DmFdlibm.atan2_(tgx - e.x, tgz - e.z)
		"support":
			if e.attackCd <= 0.0 and not silenced:
				var corpse: DmSimCorpse = null if _tr(def, "ward") else sim.nearest_corpse(e.x, e.z, 8.0)
				if corpse != null:
					e.state = "channel"
					e.stateT = 0.0
					e.channelCorpse = corpse.id
					e.aimX = corpse.x
					e.aimZ = corpse.z
					sim.emit({"t": "telegraph", "id": e.id, "kind": "raise", "x": e.x, "z": e.z, "tx": corpse.x, "tz": corpse.z, "ms": 1500.0 * (0.85 if e.elite else 1.0)})
					return
				if dist <= float(def["attackRange"]):
					e.state = "windup"
					e.stateT = 0.0
					e.aimX = tgx
					e.aimZ = tgz
					sim.emit({"t": "telegraph", "id": e.id, "kind": "curse", "x": e.x, "z": e.z, "tx": tgx, "tz": tgz, "ms": wms})
					return
			if dist > float(def["attackRange"]) - 0.5:
				move_enemy(sim, e, tgx, tgz, dt)
			elif dist < 4.0:
				move_enemy(sim, e, e.x * 2.0 - tgx, e.z * 2.0 - tgz, dt, 0.7)


static func release(sim: DmWorldSim, e: DmSimEnemy) -> void:
	var def: Dictionary = DmSimData.ENEMIES[e.def]
	e.attackCd = (float(def["cooldownMs"]) / 1000.0) * (0.8 if e.elite else 1.0)
	e.state = "recover"
	e.stateT = 0.0
	if e.channelCorpse >= 0:
		var c: DmSimCorpse = sim.corpses.get(e.channelCorpse)
		e.channelCorpse = -1
		if c != null:
			sim.remove_corpse(c, "raised")
			sim.spawn_enemy("risen", e.area, c.x, c.z, false)
		return
	if e.erupting != null:
		var B: Dictionary = DmSimData.BURROW
		e.erupting = null
		var p := sim.nav.resolve_in_area(e.area, e.aimX, e.aimZ, e.radius)
		e.x = p[0]
		e.z = p[1]
		var dmg := sim.blow(e) * (float(B["eruptMultGraves"]) if e.area == "graves" else float(B["eruptMult"]))
		for pl: DmSimPlayer in sim.players.values():
			if pl.alive and _h(pl.x - e.aimX, pl.z - e.aimZ) <= float(B["eruptR"]):
				sim.emit({"t": "hurt", "player": pl.id, "dmg": dmg, "from": "erupt", "x": e.x, "z": e.z})
		for t: DmSimThrall in sim.thralls.values():
			if _h(t.x - e.aimX, t.z - e.aimZ) <= float(B["eruptR"]):
				sim.hurt_thrall(t, dmg)
		sim.emit({"t": "erupt", "id": e.id, "x": e.aimX, "z": e.aimZ, "r": B["eruptR"]})
		return
	if e.hooking:
		e.hooking = false
		strike(sim, e, "hook")
		return
	if e.diving and _tr(def, "dive"):
		end_dive(sim, e)
		e.groundT = float(def["dive"]["groundedS"])
		strike(sim, e, "slam", float(def["dive"]["radius"]))
		return
	match def["behavior"]:
		"caster":
			strike(sim, e, def.get("attack", "cone"))
		"support":
			strike(sim, e, "curse")
		"hazard":
			strike(sim, e, "slam")
			if _tr(def, "slamPool"):
				var SP: Dictionary = DmSimData.SLAG_POOL
				sim.ember_pool(e.aimX, e.aimZ, float(def["slamRadius"]) if _tr(def, "slamRadius") else 1.9, float(SP["poolS"]), sim.blow(e) * float(SP["poolDpsMult"]))
		_:
			strike(sim, e, "melee")
			if _tr(def, "hitRun"):
				e.fleeT = float(def["hitRun"])


## A dive ends (landed or stunned out of the air): settle onto walkable ground.
static func end_dive(sim: DmWorldSim, e: DmSimEnemy) -> void:
	e.diving = false
	var p := sim.nav.resolve_in_area(e.area, e.x, e.z, e.radius)
	e.x = p[0]
	e.z = p[1]


## Weeping Seraph: Sanctify every ally in reach at once, if at least one other body is there to bless.
static func seraph_ward(sim: DmWorldSim, e: DmSimEnemy) -> void:
	var allies: Array = []
	for o: DmSimEnemy in sim.enemies.values():
		if o == e or o.state == "dead" or o.state == "rising" or o.state == "burrow" or o.sanctT > 0.0:
			continue
		if _h(o.x - e.x, o.z - e.z) <= float(DmSimData.WARD["range"]):
			allies.append(o)
	if allies.is_empty():
		return
	allies = DmStableSort.sorted(allies, func(a: DmSimEnemy, b: DmSimEnemy) -> bool: return a.hp / a.maxHp < b.hp / b.maxHp)
	for o: DmSimEnemy in allies.slice(0, int(DmSimData.WARD["maxTargets"])):
		o.sanctT = float(DmSimData.SANCTIFIED["durationS"])
		sim.emit({"t": "sanctify", "id": e.id, "target": o.id, "x": e.x, "z": e.z, "tx": o.x, "tz": o.z})
	e.attackCd = float(DmSimData.ENEMIES[e.def]["cooldownMs"]) / 1000.0


# --- Barrow Ghoul ---

static func erupt_ms(e: DmSimEnemy) -> float:
	var B: Dictionary = DmSimData.BURROW
	return (float(B["eruptMsGraves"]) if e.area == "graves" else float(B["eruptMs"])) * (0.85 if e.elite else 1.0)


## Barrow Ghoul underground: tunnel toward the target, then wind up an eruption (at most a few per target).
static func tick_burrow(sim: DmWorldSim, e: DmSimEnemy, dt: float) -> void:
	var B: Dictionary = DmSimData.BURROW
	var target: Variant = pick_target(sim, e)
	e.targetPlayer = target["player"].id if (target != null and target["player"] != null) else ""
	e.targetThrall = target["thrall"].id if (target != null and target["thrall"] != null) else -1
	if target == null:
		return
	var key: Variant = target["player"].id if target["player"] != null else target["thrall"].id
	var tx: float = target["x"]
	var tz: float = target["z"]
	var d := _h(tx - e.x, tz - e.z)
	var left: float = INF if e.burrowLeft == null else float(e.burrowLeft)
	if d <= float(B["surfaceR"]) or left <= 0.0:
		var busy := 0
		for o: DmSimEnemy in sim.enemies.values():
			if o != e and o.erupting != null and typeof(o.erupting) == typeof(key) and o.erupting == key and o.state == "windup":
				busy += 1
		if busy >= int(B["maxPerTarget"]):
			return
		e.state = "windup"
		e.stateT = 0.0
		e.erupting = key
		e.aimX = tx
		e.aimZ = tz
		e.facing = DmFdlibm.atan2_(tx - e.x, tz - e.z)
		sim.emit({"t": "telegraph", "id": e.id, "kind": "erupt", "x": e.x, "z": e.z, "tx": tx, "tz": tz, "ms": erupt_ms(e), "r": B["eruptR"]})
		return
	var px := e.x
	var pz := e.z
	move_enemy(sim, e, tx, tz, dt, float(B["speed"]) / e.speed)
	if e.burrowLeft != null:
		e.burrowLeft = float(e.burrowLeft) - _h(e.x - px, e.z - pz)


## Lich Acolyte Unbindings waiting to climb out.
static func tick_unbinds(sim: DmWorldSim) -> void:
	var i := sim.unbinds.size() - 1
	while i >= 0:
		var u: Dictionary = sim.unbinds[i]
		if sim.time < float(u["at"]):
			i -= 1
			continue
		sim.unbinds.remove_at(i)
		var a: DmSimEnemy = sim.enemies.get(int(u["by"]))
		if a == null or a.state == "dead" or a.hp <= 0.0:
			i -= 1
			continue
		sim.spawn_enemy("risen", u["area"], float(u["x"]), float(u["z"]), false).unboundBy = a.id
		i -= 1


## Censer Bearer: each second the incense Incenses every living dead within reach (itself too).
static func censer_pulse(sim: DmWorldSim, e: DmSimEnemy, dt: float) -> void:
	e.auraCd -= dt
	if e.auraCd > 0.0:
		return
	e.auraCd = 1.0
	for o: DmSimEnemy in sim.enemies.values():
		if o.state == "dead" or o.area != e.area or _h(o.x - e.x, o.z - e.z) > float(DmSimData.CENSER["radius"]):
			continue
		o.incenseT = maxf(o.incenseT, float(DmSimData.CENSER["hasteS"]))


# --- Elite affixes ---

static func tick_affix(sim: DmWorldSim, e: DmSimEnemy, dt: float) -> void:
	# The first affix keeps its clock on the enemy itself; extras keep theirs in their own dictionaries.
	if e.affix != "":
		var st := {"affixCd": e.affixCd, "tollAt": e.tollAt}
		tick_affix_kind(sim, e, e.affix, st, dt)
		e.affixCd = st["affixCd"]
		e.tollAt = st["tollAt"]
	for x: Dictionary in e.extra:
		tick_affix_kind(sim, e, x["affix"], x, dt)


static func tick_affix_kind(sim: DmWorldSim, e: DmSimEnemy, kind: String, st: Dictionary, dt: float) -> void:
	match kind:
		"bellTolled":
			var T: Dictionary = DmSimData.AFFIX_TUNING["bellTolled"]
			if st["tollAt"] != null:
				if sim.time >= float(st["tollAt"]["t"]):
					var ta: Dictionary = st["tollAt"]
					st["tollAt"] = null
					sound_toll(sim, e, float(ta["x"]), float(ta["z"]))
				return
			st["affixCd"] = (float(T["intervalS"]) if st["affixCd"] == null else float(st["affixCd"])) - dt
			if float(st["affixCd"]) > 0.0:
				return
			st["affixCd"] = float(T["intervalS"])
			st["tollAt"] = {"t": sim.time + float(T["windupS"]), "x": e.x, "z": e.z}
			sim.emit({"t": "telegraph", "id": e.id, "kind": "toll", "x": e.x, "z": e.z, "tx": e.x, "tz": e.z, "ms": float(T["windupS"]) * 1000.0, "r": T["r"]})
		"hungering":
			var T: Dictionary = DmSimData.AFFIX_TUNING["hungering"]
			st["affixCd"] = (float(T["intervalS"]) if st["affixCd"] == null else float(st["affixCd"])) - dt
			if float(st["affixCd"]) > 0.0:
				return
			var c: DmSimCorpse = sim.nearest_corpse(e.x, e.z, float(T["reach"])) if e.hp < e.maxHp else null
			if c == null:
				st["affixCd"] = 0.5
				return
			st["affixCd"] = float(T["intervalS"])
			var heal := minf(e.maxHp - e.hp, e.maxHp * float(T["healFrac"]))
			e.hp += heal
			sim.emit({"t": "affix", "id": e.id, "affix": "hungering", "x": e.x, "z": e.z, "tx": c.x, "tz": c.z, "amount": DmMath.js_round(heal)})
			sim.remove_corpse(c, "devoured")


static func sound_toll(sim: DmWorldSim, e: DmSimEnemy, x: float, z: float) -> void:
	var T: Dictionary = DmSimData.AFFIX_TUNING["bellTolled"]
	var dmg := sim.blow(e) * float(T["damageMult"])
	for p: DmSimPlayer in sim.players.values():
		if p.alive and _h(p.x - x, p.z - z) <= float(T["r"]):
			sim.emit({"t": "hurt", "player": p.id, "dmg": dmg, "from": "toll", "x": x, "z": z})
	for t: DmSimThrall in sim.thralls.values():
		if _h(t.x - x, t.z - z) <= float(T["r"]):
			sim.hurt_thrall(t, dmg)
	sim.emit({"t": "affix", "id": e.id, "affix": "bellTolled", "x": x, "z": z, "r": T["r"]})


## Vengeful elites burst into Risen where they fall.
static func vengeance(sim: DmWorldSim, e: DmSimEnemy) -> void:
	var n := int(DmSimData.AFFIX_TUNING["vengeful"]["risen"])
	sim.emit({"t": "affix", "id": e.id, "affix": "vengeful", "x": e.x, "z": e.z, "r": 1.8})
	var spin := sim.rand() * PI * 2.0
	for i in n:
		var ang := spin + (float(i) / float(n)) * PI * 2.0
		var p := sim.nav.resolve_in_area(e.area, e.x + DmFdlibm.cos_(ang) * 1.4, e.z + DmFdlibm.sin_(ang) * 1.4, 0.45)
		sim.spawn_enemy("risen", e.area, p[0], p[1], false)
