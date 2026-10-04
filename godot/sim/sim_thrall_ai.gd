class_name DmSimThrallAI
extends RefCounted
## Thrall AI of WorldSim.ts: target choice, engage/attack, formation following, wall-aware movement, soft body separation.

static func _h(a: float, b: float) -> float:
	return DmSimMath.hypot(a, b)


static func update_thralls(sim: DmWorldSim, dt: float) -> void:
	for t: DmSimThrall in sim.thralls.values():
		if t.echoUntil >= 0.0 and sim.time >= t.echoUntil:
			sim.kill_thrall(t, "crumbled")
			continue
		t.moving = false
		t.flash = maxf(0.0, t.flash - dt * 5.0)
		t.stateT += dt
		var rallied := t.rallyT > 0.0
		if rallied:
			t.rallyT = maxf(0.0, t.rallyT - dt)
		if t.cursedT > 0.0:
			t.cursedT = maxf(0.0, t.cursedT - dt)
		t.attackCd -= dt * (float(DmSimData.RALLY["attackSpeedMult"]) if rallied else 1.0)
		var owner: DmSimPlayer = sim.players.get(t.owner)
		if owner == null or not owner.alive:
			sim.kill_thrall(t, "crumbled")
			continue
		if t.state == "rising":
			if t.stateT >= DmSimConsts.THRALL_RISE_TIME:
				t.state = "idle"
				t.stateT = 0.0
			continue
		var owner_dist := _h(owner.x - t.x, owner.z - t.z)
		if owner_dist > DmSimConsts.THRALL_TELEPORT:
			t.x = owner.x + (sim.rand() - 0.5) * 2.0
			t.z = owner.z + (sim.rand() - 0.5) * 2.0
			t.target = -1
		var target: DmSimEnemy = sim.enemies.get(t.target) if t.target >= 0 else null
		var bs := sim.boss.state
		var boss_target: bool = bs.active and bs.state != "sunk" and _h(bs.x - owner.x, bs.z - owner.z) < 16.0
		if target == null or target.state == "dead" or target.state == "burrow" or (target.erupting != null and target.state == "windup") \
				or (owner.area != "" and target.area != owner.area) or _h(target.x - owner.x, target.z - owner.z) > DmSimConsts.THRALL_LEASH:
			target = null
			t.target = -1
			var best_d := 10.0
			for e: DmSimEnemy in sim.enemies.values():
				if e.state == "dead" or e.state == "rising" or e.state == "burrow" or (e.erupting != null and e.state == "windup") or (owner.area != "" and e.area != owner.area):
					continue
				if _h(e.x - owner.x, e.z - owner.z) > DmSimConsts.THRALL_LEASH - 2.0:
					continue
				var d := _h(e.x - t.x, e.z - t.z)
				if d < best_d:
					best_d = d
					target = e
			if target != null:
				t.target = target.id

		if target != null:
			var e := target
			if _engage(sim, t, e.x, e.z, e.radius, dt):
				var dealt := sim.damage_enemy(e, t.damage * (float(DmSimData.RALLY["damageMult"]) if t.rallyT > 0.0 else 1.0) * sim.cursed_mult(t) * sim.rally_mult(t, e), t.owner, [t.x, t.z])
				if t.kind == "wraith":
					e.chillT = float(DmSimData.CHILL["durationS"])
					bell_heal(sim, t)
				elif t.kind == "bonemage":
					e.hexT = float(DmSimData.BONE_HEX["durationS"])
				elif t.kind == "colossus":
					colossus_cleave(sim, t, e)
				sim.emit({"t": "thrallHit", "id": t.id, "target": e.id, "x": t.x, "z": t.z, "tx": e.x, "tz": e.z, "kind": t.kind, "dmg": DmMath.js_round(dealt)})
		elif boss_target:
			var b := sim.boss.state
			if _engage(sim, t, b.x, b.z, DmSimConsts.BOSS_RADIUS, dt):
				var raw := t.damage * (float(DmSimData.RALLY["damageMult"]) if t.rallyT > 0.0 else 1.0) * sim.cursed_mult(t) * sim.rally_mult(t, null)
				var worth := raw * (1.0 + float(DmSimData.FRACTURE["perStack"]) * b.fracture)
				sim.boss.damage(raw, t.owner, 0.0)
				sim.emit({"t": "thrallHit", "id": t.id, "target": -1, "x": t.x, "z": t.z, "tx": b.x, "tz": b.z, "kind": t.kind, "dmg": DmMath.js_round(worth)})
		else:
			# Formation ring around the owner; seats are dealt by rank among the living.
			var living := 0
			var rank := 0
			for o: DmSimThrall in sim.thralls.values():
				if o.owner != t.owner or o.state == "dead":
					continue
				living += 1
				if o.slot < t.slot:
					rank += 1
			var count := maxi(3, living)
			var ang := (float(rank) / float(count)) * PI * 2.0 + PI
			var fx := owner.x + sin(ang) * 1.9
			var fz := owner.z + cos(ang) * 1.9
			var d := _h(fx - t.x, fz - t.z)
			var seat_v := 0.0
			if not is_nan(t.seatX) and dt > 1e-5:
				seat_v = minf(12.0, _h(fx - t.seatX, fz - t.seatZ) / dt)
			t.seatX = fx
			t.seatZ = fz
			var following := t.state == "move" and (d > DmSimConsts.FOLLOW_ARRIVE or seat_v > DmSimConsts.FOLLOW_SEAT_MOVING)
			if d > 0.5 or following:
				var mult := 1.35 if d > 6.0 else 1.0
				var pace := minf(t.speed * mult, seat_v + d * DmSimConsts.FOLLOW_CATCHUP)
				move_thrall(sim, t, fx, fz, dt, mult if d > 0.5 else maxf(0.05, pace / t.speed))
				t.moving = true
				t.state = "move"
			elif t.state == "move":
				t.state = "idle"


## The engage closure: walk to the target or, in reach, swing when the cooldown allows. Returns true when a blow lands (the caller applies it).
static func _engage(sim: DmWorldSim, t: DmSimThrall, tx: float, tz: float, radius: float, dt: float) -> bool:
	var d := _h(tx - t.x, tz - t.z)
	if d > t.range + radius or (sim.nav.depths_floor() != null and sim.wall_between(t.x, t.z, tx, tz)):
		move_thrall(sim, t, tx, tz, dt, 1.0)
		t.state = "move"
		return false
	t.facing = atan2(tx - t.x, tz - t.z)
	if t.attackCd <= 0.0:
		t.attackCd = t.attackInterval
		t.state = "attack"
		t.stateT = 0.0
		return true
	elif t.state != "attack" or t.stateT > 0.5:
		t.state = "idle"
	return false


static func colossus_cleave(sim: DmWorldSim, t: DmSimThrall, main: DmSimEnemy) -> void:
	var C: Dictionary = DmSimData.RUNE_TUNING["colossus"]
	var dmg := t.damage * (float(DmSimData.RALLY["damageMult"]) if t.rallyT > 0.0 else 1.0) * sim.cursed_mult(t) * float(C["cleaveFrac"])
	for o: DmSimEnemy in sim.enemies.values():
		if o == main or o.state == "dead" or o.state == "burrow" or _h(o.x - main.x, o.z - main.z) > float(C["cleaveRadius"]) + o.radius:
			continue
		sim.damage_enemy(o, dmg, t.owner, [t.x, t.z])


## Mourning Bell: a wraith's hit mends every living ally near it.
static func bell_heal(sim: DmWorldSim, t: DmSimThrall) -> void:
	if t.allyHeal == 0.0:
		return
	var r := float(DmSimData.NECRO_WEAPON_TUNING["mourning_bell"]["allyHealRange"])
	for p: DmSimPlayer in sim.players.values():
		if p.alive and _h(p.x - t.x, p.z - t.z) <= r:
			sim.emit({"t": "heal", "player": p.id, "amount": 0.0, "x": p.x, "z": p.z, "frac": t.allyHeal})


static func move_thrall(sim: DmWorldSim, t: DmSimThrall, tx: float, tz: float, dt: float, mult: float) -> void:
	var hop: Variant = sim.nav.depths_hop(t.x, t.z, tx, tz)
	if hop != null:
		tx = hop["x"]
		tz = hop["z"]
	if t.hasDetour and not t.detour.is_empty() and sim.time < t.detourUntil:
		while not t.detour.is_empty() and _h(t.detour[0][0] - t.x, t.detour[0][1] - t.z) < 0.5:
			t.detour.pop_front()
		if not t.detour.is_empty():
			tx = t.detour[0][0]
			tz = t.detour[0][1]
	elif t.hasDetour:
		t.detour = []
		t.hasDetour = false
	var dx := tx - t.x
	var dz := tz - t.z
	var d := _h(dx, dz)
	if d < 0.05:
		return
	var step := minf(d, t.speed * mult * dt)
	var px := t.x
	var pz := t.z
	var p := sim.nav.resolve(t.x + (dx / d) * step, t.z + (dz / d) * step, 0.4)
	t.x = p[0]
	t.z = p[1]
	var gained := ((t.x - px) * dx + (t.z - pz) * dz) / d
	if step > 1e-3 and gained < step * 0.3:
		var s := DmSimEnemyAI.sidestep(px, pz, dx / d, dz / d, step, func(x: float, z: float) -> Array: return sim.nav.resolve(x, z, 0.4))
		t.x = s[0]
		t.z = s[1]
		t.stallT += dt
		if t.stallT > 0.5 and sim.time >= t.nextPathAt and sim.nav.depths_floor() == null:
			t.nextPathAt = sim.time + 1.5
			t.stallT = 0.0
			var path := sim.nav.find_path(t.x, t.z, tx, tz, 0.4)
			if path.size() > 1:
				t.detour = path.slice(0, path.size() - 1)
				t.hasDetour = true
				t.detourUntil = sim.time + 3.0
	elif t.stallT != 0.0:
		t.stallT = 0.0
	t.facing = atan2(dx, dz)
	t.moving = true
	t.gait += step * 2.4


## Soft body separation: enemies <-> enemies/thralls/players, thralls <-> thralls.
static func separate(sim: DmWorldSim) -> void:
	var bx: PackedFloat64Array = PackedFloat64Array()
	var bz: PackedFloat64Array = PackedFloat64Array()
	var br: PackedFloat64Array = PackedFloat64Array()
	var bw: PackedFloat64Array = PackedFloat64Array()
	var bodies: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if e.state != "rising" and e.state != "burrow":
			bx.append(e.x)
			bz.append(e.z)
			br.append(e.radius)
			bw.append(0.0 if DmCombatData.truthy(DmSimData.ENEMIES[e.def].get("inert")) else 1.0)
			bodies.append(e)
	for t: DmSimThrall in sim.thralls.values():
		bx.append(t.x)
		bz.append(t.z)
		br.append(0.4)
		bw.append(0.6)
		bodies.append(t)
	for p: DmSimPlayer in sim.players.values():
		if p.alive:
			bx.append(p.x)
			bz.append(p.z)
			br.append(DmSimConsts.PLAYER_RADIUS)
			bw.append(0.0)
			bodies.append(null)
	var n := bodies.size()
	for i in n:
		for j in range(i + 1, n):
			var dx := bx[j] - bx[i]
			var dz := bz[j] - bz[i]
			var mn := br[i] + br[j]
			if absf(dx) > mn or absf(dz) > mn:
				continue
			var d := _h(dx, dz)
			if d >= mn or d < 1e-4:
				continue
			var push := (mn - d) * 0.5
			var nx := dx / d
			var nz := dz / d
			var total := bw[i] + bw[j]
			if total == 0.0:
				total = 1.0
			var pa := (bw[i] / total) * push * 2.0
			var pb := (bw[j] / total) * push * 2.0
			bx[i] -= nx * pa
			bz[i] -= nz * pa
			bx[j] += nx * pb
			bz[j] += nz * pb
	for i in n:
		var b: Variant = bodies[i]
		if b is DmSimEnemy:
			var p := sim.nav.resolve_in_area(b.area, bx[i], bz[i], b.radius)
			b.x = p[0]
			b.z = p[1]
		elif b is DmSimThrall:
			var p := sim.nav.resolve(bx[i], bz[i], 0.4)
			b.x = p[0]
			b.z = p[1]
