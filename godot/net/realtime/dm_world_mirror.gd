class_name DmWorldMirror
extends RefCounted
## Port of `WorldMirror` (src/gameplay/sim/snapshot.ts): the read-side replica of the host's world for non-host clients.
## Entities are Dictionaries keyed by int id with the TS field names (x, z, facing, hp, maxHp, state, stateT, elite, moving, flash, ...),
## so a view layer can read them directly. `update(dt)` eases positions toward the latest snapshot. Host migration seeding (`seed`)
## belongs to the sim port: use `export_state()` to hand the replica to it.

var enemies: Dictionary = {}
var thralls: Dictionary = {}
var corpses: Dictionary = {}
var zones: Dictionary = {}
## Depleted gathering nodes -> mirror time they come back.
var depleted: Dictionary = {}
var boss_state: Variant = null
var wave_tier: int = 0
var difficulty: String = "medium"
var vows: Dictionary = {}
var time: float = 0.0
var _enemy_targets: Dictionary = {}
var _thrall_targets: Dictionary = {}

func ascension() -> int:
	return DmAscension.vow_heat(vows)

func vow_fx() -> Dictionary:
	return DmAscension.vow_effects(vows)

static func _blank_enemy(row: Array) -> Dictionary:
	return {
		"id": int(row[0]), "def": row[1], "area": row[12], "level": int(row[14]) if row.size() > 14 and row[14] != null else 1,
		"elite": false, "x": float(row[2]), "z": float(row[3]), "facing": float(row[4]), "hp": float(row[5]), "maxHp": float(row[6]),
		"damage": 0.0, "speed": float(row[10]), "radius": 0.5, "scale": float(row[11]), "state": "move", "stateT": 0.0, "attackCd": 0.0,
		"targetPlayer": null, "targetThrall": null, "aimX": 0.0, "aimZ": 0.0, "channelCorpse": null, "flankSide": 1,
		"fracture": 0, "fractureT": 0.0, "withered": 0, "witheredT": 0.0, "witheredDps": 0.0, "witheredOwner": "", "slowT": 0.0,
		"lastHitBy": "", "flash": 0.0, "gait": 0.0, "moving": false,
		"affix": DmSnapshot.affix_from(row[13] if row.size() > 13 else null),
	}

func apply_snapshot(s: Dictionary) -> void:
	time = float(s.get("t", 0.0))
	wave_tier = int(s.get("waveTier", 0))
	var d: Variant = s.get("difficulty")
	difficulty = d if d is String and d in DmSnapshot.DIFFICULTY_ORDER else "medium"
	var sv: Variant = s.get("vows")
	if sv is Dictionary:
		vows = DmAscension.sanitize_vows(sv)
	else:
		var asc: Variant = s.get("ascension", 0)
		vows = DmAscension.legacy_vows(asc if (asc is int or asc is float) and asc >= 0 and float(asc) == floorf(float(asc)) else 0)
	var seen_e := {}
	for row: Array in s.get("enemies", []):
		var id := int(row[0])
		seen_e[id] = true
		var e: Dictionary
		if enemies.has(id):
			e = enemies[id]
		else:
			e = _blank_enemy(row)
			enemies[id] = e
		var flags := int(row[8])
		var prev_hp: float = e["hp"]
		e["hp"] = float(row[5])
		e["maxHp"] = float(row[6])
		if e["hp"] < prev_hp:
			e["flash"] = 1.0
		var si := int(row[7])
		var st: String = DmSnapshot.E_STATES[si] if si >= 0 and si < DmSnapshot.E_STATES.size() else "move"
		if st != e["state"]:
			e["stateT"] = float(row[9])
		e["state"] = st
		e["elite"] = (flags & DmSnapshot.F_ELITE) != 0
		e["moving"] = (flags & DmSnapshot.F_MOVING) != 0
		e["slowT"] = 0.2 if (flags & DmSnapshot.F_SLOW) else 0.0
		e["chillT"] = 0.2 if (flags & DmSnapshot.F_CHILL) else 0.0
		e["bleedT"] = 0.2 if (flags & DmSnapshot.F_BLEED) else 0.0
		e["sanctT"] = 0.2 if (flags & DmSnapshot.F_SANCT) else 0.0
		e["hexT"] = 0.2 if (flags & DmSnapshot.F_HEX) else 0.0
		e["silenceT"] = 0.2 if (flags & DmSnapshot.F_SILENCE) else 0.0
		e["incenseT"] = 0.2 if (flags & DmSnapshot.F_INCENSE) else 0.0
		e["stunT"] = 0.2 if (flags & DmSnapshot.F_STUN) else 0.0
		e["rootT"] = 0.2 if (flags & DmSnapshot.F_ROOT) else 0.0
		e["diving"] = (flags & DmSnapshot.F_DIVING) != 0
		e["fracture"] = (flags >> 4) & 15
		e["withered"] = (flags >> 8) & 15
		e["speed"] = float(row[10])
		e["scale"] = float(row[11])
		e["affix"] = DmSnapshot.affix_from(row[13] if row.size() > 13 else null)
		_enemy_targets[id] = {"x": float(row[2]), "z": float(row[3]), "facing": float(row[4])}
	for id in enemies.keys():
		if not seen_e.has(id):
			enemies.erase(id)
			_enemy_targets.erase(id)

	var seen_t := {}
	for row: Array in s.get("thralls", []):
		var id := int(row[0])
		seen_t[id] = true
		var t: Dictionary
		if thralls.has(id):
			t = thralls[id]
		else:
			var f10 := int(row[10])
			t = {
				"id": id, "owner": str(row[1]), "kind": row[2], "x": float(row[3]), "z": float(row[4]), "facing": float(row[5]),
				"hp": float(row[6]), "maxHp": float(row[7]), "damage": float(row[12]) if row.size() > 12 and row[12] != null else 0.0,
				"attackInterval": float(row[13]) if row.size() > 13 and row[13] != null else 1.0, "range": 1.0, "speed": float(row[11]),
				"state": "rising", "stateT": float(row[9]), "attackCd": 0.0, "target": null, "slot": 0, "bornAt": 0.0,
				"empowered": (f10 & 1) != 0, "flash": 0.0, "gait": 0.0, "moving": false,
			}
			if f10 & 8:
				t["champion"] = true
			thralls[id] = t
		if float(row[6]) < t["hp"]:
			t["flash"] = 1.0
		if row.size() > 12 and row[12] != null:
			t["damage"] = float(row[12])
		if row.size() > 13 and row[13] != null:
			t["attackInterval"] = float(row[13])
		t["hp"] = float(row[6])
		t["maxHp"] = float(row[7])
		var ti := int(row[8]) & 15
		var tst: String = DmSnapshot.T_STATES[ti] if ti < DmSnapshot.T_STATES.size() else "idle"
		if tst != t["state"]:
			t["stateT"] = float(row[9])
		t["state"] = tst
		t["moving"] = (int(row[8]) & 16) != 0
		t["rallyT"] = 0.3 if (int(row[10]) & 2) else 0.0
		t["cursedT"] = 0.3 if (int(row[10]) & 4) else 0.0
		_thrall_targets[id] = {"x": float(row[3]), "z": float(row[4]), "facing": float(row[5])}
	for id in thralls.keys():
		if not seen_t.has(id):
			thralls.erase(id)
			_thrall_targets.erase(id)

	if s.has("corpses") and s["corpses"] is Array:
		corpses.clear()
		for c: Dictionary in s["corpses"]:
			corpses[int(c["id"])] = c
	if s.has("zones") and s["zones"] is Array:
		zones.clear()
		for z: Dictionary in s["zones"]:
			zones[int(z["id"])] = z
	if s.get("zpos") is Array:
		for zp: Array in s["zpos"]:
			var zone: Variant = zones.get(int(zp[0]))
			if zone != null:
				zone["x"] = float(zp[1])
				zone["z"] = float(zp[2])
	boss_state = s.get("boss")
	if s.get("depleted") is Array:
		depleted.clear()
		for dp: Array in s["depleted"]:
			if dp[0] is String:
				depleted[dp[0]] = float(s.get("t", 0.0)) + maxf(0.0, float(dp[1]) if (dp[1] is int or dp[1] is float) else 0.0)

func apply_events(events: Array) -> void:
	for ev: Dictionary in events:
		match ev.get("t"):
			"corpse": corpses[int(ev["corpse"]["id"])] = ev["corpse"]
			"corpseGone": corpses.erase(int(ev["id"]))
			"zone": zones[int(ev["zone"]["id"])] = ev["zone"]
			"zoneGone": zones.erase(int(ev["id"]))
			"death":
				enemies.erase(int(ev["id"]))
				_enemy_targets.erase(int(ev["id"]))
			"thrallGone":
				thralls.erase(int(ev["id"]))
				_thrall_targets.erase(int(ev["id"]))
			"seedGone":
				var c: Variant = corpses.get(int(ev["corpseId"]))
				if c != null:
					c.erase("seedOwner")
			"seeded":
				var c2: Variant = corpses.get(int(ev["corpseId"]))
				if c2 != null:
					c2["seedOwner"] = ev["by"]
					c2["seedArmedAt"] = time + float(ev["armMs"]) / 1000.0
			"nodeGone": depleted[str(ev["id"])] = time + float(ev["respawnS"])
			"nodeBack": depleted.erase(str(ev["id"]))

func update(dt: float) -> void:
	var k := minf(1.0, dt * 12.0)
	for id in enemies:
		var e: Dictionary = enemies[id]
		e["stateT"] += dt
		e["flash"] = maxf(0.0, e["flash"] - dt * 5.0)
		var t: Variant = _enemy_targets.get(id)
		if t == null:
			continue
		e["x"] += (t["x"] - e["x"]) * k
		e["z"] += (t["z"] - e["z"]) * k
		e["facing"] = t["facing"]
	for id in thralls:
		var th: Dictionary = thralls[id]
		th["stateT"] += dt
		th["flash"] = maxf(0.0, th["flash"] - dt * 5.0)
		var t2: Variant = _thrall_targets.get(id)
		if t2 == null:
			continue
		th["x"] += (t2["x"] - th["x"]) * k
		th["z"] += (t2["z"] - th["z"]) * k
		th["facing"] = t2["facing"]

## Everything a fresh authoritative sim needs to adopt this replica (host migration; the sim port does the adopting).
func export_state() -> Dictionary:
	return {"waveTier": wave_tier, "difficulty": difficulty, "vows": vows.duplicate(), "time": time, "enemies": enemies.values(),
		"thralls": thralls.values(), "corpses": corpses.values(), "zones": zones.values(), "boss": boss_state, "depleted": depleted.duplicate()}

func clear() -> void:
	enemies.clear(); thralls.clear(); corpses.clear(); zones.clear(); depleted.clear()
	_enemy_targets.clear(); _thrall_targets.clear()
	boss_state = null
