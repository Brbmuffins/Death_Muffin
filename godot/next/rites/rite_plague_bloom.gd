extends DmRiteModule
## Plague Bloom (the Rotweaver's signature, R): plant a rot flower at the cursor (pulled back to 14 m): radius 2.4, 8 s. Every second it adds a Withered stack (cap 8) to the enemies
## in it (dps = spell power x 0.3) and slows them; every 2 s it seeds the nearest corpse within 6 m (consuming it through the field) with a new bloom (6 s) that does the same, up to
## 3 generations deep. 28 essence, 12 s, unlocks at level 10. Numbers: DmSimData.SIGNATURE.bloom + the def; the flowers follow sim_zones (friendly zone + tick_bloom_spread).
## Also here: the Rotweaver's passive (`miasma_bursts`, called by the caster while the `miasmaBurstsCorpses` mod is set): corpses lying in her Miasma burst.
## Visuals: DmRiteFx.bloom_*. Events: `cast`, `spread`, `burst`.

const SCAN_S := 0.1
const PULSE_S := 1.0
const SLOW_HOLD_S := 0.3
const BURST_R := 2.6        ## sim_zones: a Miasma-burst corpse
const BURST_DPS_MULT := 4.0


func _init() -> void:
	id = "plague_bloom"
	steps = true


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var B: Dictionary = DmSimData.SIGNATURE["bloom"]
	var at := clamp_reach(c.pos(), intent["aim"], float(DmAbilities.def(id)["range"]))
	var dps := DmAbilities.sp(c.p, c.now_ms) * float(DmAbilities.def(id)["power"])
	_plant(c, at.x, at.z, dps, float(B["durationS"]), 0)
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "tip": c.tip(), "x": at.x, "z": at.z, "r": float(B["radius"]), "ms": float(B["durationS"]) * 1000.0})
	return ""


func _plant(c: DmRiteCaster, x: float, z: float, dps: float, seconds: float, gen: int) -> void:
	var B: Dictionary = DmSimData.SIGNATURE["bloom"]
	c.mem(id).get_or_add("zones", []).append({"x": x, "z": z, "r": float(B["radius"]), "dps": dps, "cap": float(B["witheredCap"]), "gen": gen,
		"until": c.now_ms + seconds * 1000.0, "scan": 0.0, "pulse": 0.0, "spread": float(B["spreadEveryS"])})


func step(c: DmRiteCaster, dt: float) -> void:
	var zones: Array = c.mem(id).get("zones", [])
	var i := 0
	while i < zones.size():   # (a flower planted this tick is appended: it waits for the next)
		var z: Dictionary = zones[i]
		if c.now_ms >= float(z["until"]):
			zones.remove_at(i)
			continue
		i += 1
		z["scan"] = float(z["scan"]) - dt
		z["pulse"] = float(z["pulse"]) - dt
		var pulse: bool = z["pulse"] <= 0.0
		if pulse:
			z["pulse"] = float(z["pulse"]) + PULSE_S
		if pulse or z["scan"] <= 0.0:
			z["scan"] = SCAN_S
			_afflict(c, z, pulse)
		if int(z["gen"]) < int(DmSimData.SIGNATURE["bloom"]["maxGenerations"]):
			z["spread"] = float(z["spread"]) - dt
			if z["spread"] <= 0.0:
				z["spread"] = float(DmSimData.SIGNATURE["bloom"]["spreadEveryS"])
				_spread(c, z)


## The flower's reach: slow while an enemy stands in it, +1 Withered (strongest dps) each pulse. Same rules as the Miasma cloud.
func _afflict(c: DmRiteCaster, z: Dictionary, pulse: bool) -> void:
	var at := Vector3(z["x"], 0.0, z["z"])
	for n in c.world.enemies_in_radius(at, float(z["r"]) + 2.0):
		var e := n as Node3D
		if e == null or not DmRiteCaster.alive_enemy(e):
			continue
		if Vector2(e.global_position.x - at.x, e.global_position.z - at.z).length() > float(z["r"]) + float(e.get("radius")):
			continue
		var ss := DmStatusSet.ensure(e)
		c.watch_dots(ss)
		ss.apply(&"slow", c.body, 1, SLOW_HOLD_S)
		if pulse:
			ss.apply(&"withered", c.body, 1, -1.0, {"dps": float(z["dps"]), "cap": float(z["cap"])})


## Seed the nearest corpse (more than 0.5 m and at most spreadReach away) with a child bloom.
func _spread(c: DmRiteCaster, z: Dictionary) -> void:
	var field := c.corpses()
	if field == null:
		return
	var B: Dictionary = DmSimData.SIGNATURE["bloom"]
	var at := Vector3(z["x"], 0.0, z["z"])
	var best: DmSimCorpse = null
	var best_d := float(B["spreadReach"])
	for cp: DmSimCorpse in field.corpses_in_radius(at, best_d, Callable(), c.area()):
		var d := Vector2(cp.x - at.x, cp.z - at.z).length()
		if d > 0.5 and d < best_d:
			best_d = d
			best = cp
	if best == null:
		return
	var x := best.x
	var zz := best.z
	if not field.consume(best.id, c.peer_id, "consumed"):
		return
	_plant(c, x, zz, float(z["dps"]), float(B["childDurationS"]), int(z["gen"]) + 1)
	c.broadcast({"t": "spread", "rite": id, "by": c.peer_id, "x0": at.x, "z0": at.z, "x": x, "z": zz, "r": float(B["radius"]), "ms": float(B["childDurationS"]) * 1000.0})


## Rotweaver passive (sim_zones: a Miasma zone with `bloom`): every corpse lying in her cloud bursts once, 2.6 m, dps x 4, +1 Withered up to the cloud's cap. Scans at 4 Hz.
## Reads the Miasma module's zones (`c.mem("miasma")["zones"]`: x, z, r, dps, cap).
static func miasma_bursts(c: DmRiteCaster, dt: float) -> void:
	var zones: Array = c.mem("miasma").get("zones", [])
	var field := c.corpses()
	if zones.is_empty() or field == null:
		return
	var m := c.mem("plague_bloom")
	m["burst_scan"] = float(m.get("burst_scan", 0.0)) - dt
	if m["burst_scan"] > 0.0:
		return
	m["burst_scan"] = 0.25
	for z: Dictionary in zones:
		for cp: DmSimCorpse in field.corpses_in_radius(Vector3(z["x"], 0.0, z["z"]), float(z["r"]), Callable(), c.area()):
			var x := cp.x
			var zz := cp.z
			if not field.consume(cp.id, c.peer_id, "burst"):
				continue
			var dmg := float(z["dps"]) * BURST_DPS_MULT
			for n in c.world.enemies_in_radius(Vector3(x, 0.0, zz), BURST_R + 2.0):
				var e := n as Node3D
				if e == null or not DmRiteCaster.alive_enemy(e) or Vector2(e.global_position.x - x, e.global_position.z - zz).length() > BURST_R + float(e.get("radius")):
					continue
				DmStatusSet.hit(e, dmg, c.body)
				var ss := DmStatusSet.ensure(e)
				c.watch_dots(ss)
				ss.apply(&"withered", c.body, 1, -1.0, {"dps": float(z["dps"]), "cap": float(z["cap"])})
				c.hit_resolved.emit("plague_bloom", int(c.world.enemy_id(e)), dmg, false, float(e.get("hp")) <= 0.0)
			c.broadcast({"t": "burst", "rite": "plague_bloom", "by": c.peer_id, "x": x, "z": zz, "r": BURST_R})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"cast":
			c.fx.signature_cast("bloom", ev["tip"])
			c.fx.bloom_zone(float(ev["x"]), float(ev["z"]), float(ev["r"]), float(ev["ms"]) / 1000.0)
		"spread":
			c.fx.bloom_spread(float(ev["x0"]), float(ev["z0"]), float(ev["x"]), float(ev["z"]))
			c.fx.bloom_zone(float(ev["x"]), float(ev["z"]), float(ev["r"]), float(ev["ms"]) / 1000.0)
		"burst":
			c.fx.bloom_burst(float(ev["x"]), float(ev["z"]), float(ev["r"]))
