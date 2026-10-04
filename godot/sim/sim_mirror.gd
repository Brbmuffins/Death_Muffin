class_name DmSimMirror
extends RefCounted
## Port of WorldMirror (src/gameplay/sim/snapshot.ts): the read-side replica of the host's DmWorldSim for non-host clients. Snapshots arrive
## at ~10 Hz (DmSimSnapshot.make form); positions ease toward them every frame. Corpses and zones arrive as reliable events, with a full list
## every few snapshots to heal drift. `seed(sim)` hands the replicated state to a fresh authoritative sim (host migration).

var enemies: Dictionary = {}
var thralls: Dictionary = {}
var corpses: Dictionary = {}
var zones: Dictionary = {}
## Depleted gathering nodes -> mirror time they come back.
var depleted: Dictionary = {}
var bossState: Variant = null
var waveTier: float = 0.0
var difficulty: String = "medium"
var vows: Dictionary = {}
var time: float = 0.0
var _enemy_targets: Dictionary = {}
var _thrall_targets: Dictionary = {}


func ascension() -> float:
	return DmVowsBoons.vow_heat(vows)


func vow_fx() -> Dictionary:
	return DmVowsBoons.vow_effects(vows)


static func _affix_from(code: Variant) -> String:
	var c := int(code) if (code is float or code is int) else 0
	return DmSimData.AFFIX_ORDER[c - 1] if c > 0 else ""


static func _blank_enemy(row: Array) -> DmSimEnemy:
	DmSimData.ensure()
	var e := DmSimEnemy.new()
	e.id = int(row[0])
	e.def = row[1]
	e.area = row[12]
	e.level = float(row[14]) if (row.size() > 14 and row[14] != null) else 1.0
	e.x = float(row[2])
	e.z = float(row[3])
	e.facing = float(row[4])
	e.hp = float(row[5])
	e.maxHp = float(row[6])
	e.speed = float(row[10])
	e.scale = float(row[11])
	e.affix = _affix_from(row[13] if row.size() > 13 else 0)
	return e


func apply_snapshot(s: Dictionary) -> void:
	DmSimData.ensure()
	time = float(s["t"])
	waveTier = float(s["waveTier"])
	var d: Variant = s.get("difficulty")
	difficulty = d if (d is String and DmContent.difficulties().has(d)) else "medium"
	if s.get("vows") is Dictionary:
		vows = DmAscension.sanitize_vows(s["vows"])
	else:
		var a: Variant = s.get("ascension")
		vows = DmVowsBoons.legacy_vows(float(a) if ((a is float or a is int) and float(a) >= 0.0 and float(a) == floorf(float(a))) else 0.0)
	var seen_e: Dictionary = {}
	for row: Array in s["enemies"]:
		var id := int(row[0])
		seen_e[id] = true
		var e: DmSimEnemy = enemies.get(id)
		if e == null:
			e = _blank_enemy(row)
			enemies[id] = e
		var flags := int(row[8])
		var prev_hp := e.hp
		e.hp = float(row[5])
		e.maxHp = float(row[6])
		if e.hp < prev_hp:
			e.flash = 1.0
		var st: String = DmSimSnapshot.E_STATES[int(row[7])] if (int(row[7]) >= 0 and int(row[7]) < DmSimSnapshot.E_STATES.size()) else "move"
		if st != e.state:
			e.stateT = float(row[9])
		e.state = st
		e.elite = (flags & 1) != 0
		e.moving = (flags & 2) != 0
		e.slowT = 0.2 if (flags & 4) != 0 else 0.0
		e.chillT = 0.2 if (flags & 8) != 0 else 0.0
		e.bleedT = 0.2 if (flags & 4096) != 0 else 0.0
		e.sanctT = 0.2 if (flags & 8192) != 0 else 0.0
		e.hexT = 0.2 if (flags & 16384) != 0 else 0.0
		e.silenceT = 0.2 if (flags & 32768) != 0 else 0.0
		e.incenseT = 0.2 if (flags & 65536) != 0 else 0.0
		e.stunT = 0.2 if (flags & 131072) != 0 else 0.0
		e.rootT = 0.2 if (flags & 262144) != 0 else 0.0
		e.diving = (flags & 524288) != 0
		e.fracture = float((flags >> 4) & 15)
		e.withered = float((flags >> 8) & 15)
		e.speed = float(row[10])
		e.scale = float(row[11])
		e.affix = _affix_from(row[13] if row.size() > 13 else 0)
		var tg: Variant = _enemy_targets.get(id)
		if tg != null:
			tg["x"] = float(row[2])
			tg["z"] = float(row[3])
			tg["facing"] = float(row[4])
		else:
			_enemy_targets[id] = {"x": float(row[2]), "z": float(row[3]), "facing": float(row[4])}
	for id in enemies.keys():
		if not seen_e.has(id):
			enemies.erase(id)
			_enemy_targets.erase(id)

	var seen_t: Dictionary = {}
	for row: Array in s["thralls"]:
		var id := int(row[0])
		seen_t[id] = true
		var t: DmSimThrall = thralls.get(id)
		if t == null:
			t = DmSimThrall.new()
			t.id = id
			t.owner = row[1]
			t.kind = row[2]
			t.x = float(row[3])
			t.z = float(row[4])
			t.facing = float(row[5])
			t.hp = float(row[6])
			t.maxHp = float(row[7])
			t.damage = float(row[12]) if (row.size() > 12 and row[12] != null) else 0.0
			t.attackInterval = float(row[13]) if (row.size() > 13 and row[13] != null) else 1.0
			t.range = 1.0
			t.speed = float(row[11])
			t.state = "rising"
			t.stateT = float(row[9])
			t.empowered = (int(row[10]) & 1) != 0
			if (int(row[10]) & 8) != 0:
				t.champion = true
			thralls[id] = t
		if float(row[6]) < t.hp:
			t.flash = 1.0
		if row.size() > 12 and row[12] != null:
			t.damage = float(row[12])
		if row.size() > 13 and row[13] != null:
			t.attackInterval = float(row[13])
		t.hp = float(row[6])
		t.maxHp = float(row[7])
		var ts: int = int(row[8]) & 15
		var st: String = DmSimSnapshot.T_STATES[ts] if ts < DmSimSnapshot.T_STATES.size() else "idle"
		if st != t.state:
			t.stateT = float(row[9])
		t.state = st
		t.moving = (int(row[8]) & 16) != 0
		t.rallyT = 0.3 if (int(row[10]) & 2) != 0 else 0.0
		t.cursedT = 0.3 if (int(row[10]) & 4) != 0 else 0.0
		var tg: Variant = _thrall_targets.get(id)
		if tg != null:
			tg["x"] = float(row[3])
			tg["z"] = float(row[4])
			tg["facing"] = float(row[5])
		else:
			_thrall_targets[id] = {"x": float(row[3]), "z": float(row[4]), "facing": float(row[5])}
	for id in thralls.keys():
		if not seen_t.has(id):
			thralls.erase(id)
			_thrall_targets.erase(id)

	if s.has("corpses"):
		corpses.clear()
		for c: Dictionary in s["corpses"]:
			corpses[int(c["id"])] = DmSimCorpse.from_dict(c)
	if s.has("zones"):
		zones.clear()
		for z: Dictionary in s["zones"]:
			zones[int(z["id"])] = DmSimZone.from_dict(z)
	if s.get("zpos") is Array:
		for p: Array in s["zpos"]:
			var zone: DmSimZone = zones.get(int(p[0]))
			if zone != null:
				zone.x = float(p[1])
				zone.z = float(p[2])
	var bs := DmBossState.new()
	bs.from_dict(s["boss"])
	bossState = bs
	if s.get("depleted") is Array:
		depleted.clear()
		for p: Array in s["depleted"]:
			if p[0] is String:
				depleted[p[0]] = time + maxf(0.0, float(p[1]))


## Events in the relay form (DmSimSnapshot.wire_event), or the host's own (objects in `corpse`/`zone`).
func apply_events(events: Array) -> void:
	for ev: Dictionary in events:
		match ev["t"]:
			"corpse":
				var c: Variant = ev["corpse"]
				var co: DmSimCorpse = c if c is DmSimCorpse else DmSimCorpse.from_dict(c)
				corpses[co.id] = co
			"corpseGone":
				corpses.erase(int(ev["id"]))
			"zone":
				var z: Variant = ev["zone"]
				var zn: DmSimZone = z if z is DmSimZone else DmSimZone.from_dict(z)
				zones[zn.id] = zn
			"zoneGone":
				zones.erase(int(ev["id"]))
			"death":
				enemies.erase(int(ev["id"]))
				_enemy_targets.erase(int(ev["id"]))
			"thrallGone":
				thralls.erase(int(ev["id"]))
				_thrall_targets.erase(int(ev["id"]))
			"seedGone":
				var c2: DmSimCorpse = corpses.get(int(ev["corpseId"]))
				if c2 != null:
					c2.seedOwner = ""
			"seeded":
				var c3: DmSimCorpse = corpses.get(int(ev["corpseId"]))
				if c3 != null:
					c3.seedOwner = ev["by"]
					c3.seedArmedAt = time + float(ev["armMs"]) / 1000.0
			"nodeGone":
				depleted[ev["id"]] = time + float(ev["respawnS"])
			"nodeBack":
				depleted.erase(ev["id"])


func update(dt: float) -> void:
	var k := minf(1.0, dt * 12.0)
	for e: DmSimEnemy in enemies.values():
		e.stateT += dt
		e.flash = maxf(0.0, e.flash - dt * 5.0)
		var t: Variant = _enemy_targets.get(e.id)
		if t == null:
			continue
		e.x += (t["x"] - e.x) * k
		e.z += (t["z"] - e.z) * k
		e.facing = t["facing"]
	for th: DmSimThrall in thralls.values():
		th.stateT += dt
		th.flash = maxf(0.0, th.flash - dt * 5.0)
		var t: Variant = _thrall_targets.get(th.id)
		if t == null:
			continue
		th.x += (t["x"] - th.x) * k
		th.z += (t["z"] - th.z) * k
		th.facing = t["facing"]


static func _clone(o: RefCounted) -> RefCounted:
	var c: RefCounted = o.get_script().new()
	for p in o.get_property_list():
		if (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			c.set(p["name"], o.get(p["name"]))
	return c


## Host migration: hand the replicated state to a fresh authoritative sim.
func seed(sim: DmWorldSim) -> void:
	sim.waveTier = waveTier
	sim.difficulty = difficulty
	sim.vows = vows
	for e: DmSimEnemy in enemies.values():
		sim.enemies[e.id] = sim.adopt_enemy(_clone(e))
	var ordered: Array = DmStableSort.sorted(thralls.values(), func(a: DmSimThrall, b: DmSimThrall) -> bool: return a.id < b.id)
	var seats: Dictionary = {}
	for i in ordered.size():
		var t: DmSimThrall = _clone(ordered[i])
		var slot: int = int(seats.get(t.owner, 0))
		seats[t.owner] = slot + 1
		t.damage = t.damage if t.damage != 0.0 else 6.0
		t.attackInterval = t.attackInterval if t.attackInterval > 0.0 else 1.0
		t.range = DmThralls.reach(t.kind)
		t.slot = slot
		t.bornAt = sim.time - float(ordered.size() - i) * 1e-3
		sim.thralls[t.id] = t
	for c: DmSimCorpse in corpses.values():
		var cc: DmSimCorpse = _clone(c)
		cc.bornAt = sim.time
		cc.expiresAt = sim.time + 20.0
		cc.ruptureAt = sim.time + 4.0 if cc.kind == "toxic" else INF
		sim.corpses[cc.id] = cc
	if bossState != null and bossState.active:
		sim.adopt_boss(bossState)
	for id in depleted:
		var n: Variant = sim.nodes.get(id)
		if n != null:
			n["remaining"] = 0.0
			n["respawnAt"] = sim.time + maxf(0.0, float(depleted[id]) - time)
	var max_id := 0
	for k in enemies.keys():
		max_id = maxi(max_id, k)
	for k in thralls.keys():
		max_id = maxi(max_id, k)
	for k in corpses.keys():
		max_id = maxi(max_id, k)
	for k in zones.keys():
		max_id = maxi(max_id, k)
	sim.reserve_ids(max_id)
