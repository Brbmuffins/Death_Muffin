extends DmRiteModule
## Miasma Circle: ground-targeted, 25 essence, 7 s, radius 3.8 x mods, a 6 s Withered cloud (+1 stack per second, slow 0.6). Numbers:
## DmAbilities.miasma + DmSimData (WITHERED, MIASMA_SLOW); visuals: DmRiteFx.miasma_land (shared with the current game).

const SPEED := 18.0        ## sim_caster._miasma projectile
const TARGET_Y := 0.2
const ARC := 12.0
const SLOW_HOLD_S := 0.3   ## the cloud keeps its slow on for this long after the last scan an enemy stood in it
const SCAN_S := 0.1        ## a cloud looks for enemies 10x/s (not every frame); the hold above covers the gap


func _init() -> void:
	id = "miasma"
	steps = true


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var aim: Vector3 = intent["aim"]
	var m := DmAbilities.miasma(DmAbilities.sp(c.p, c.now_ms), c.mods, DmAbilities.rune(c.p, id), float(intent.get("mult", 1.0)), {"x": c.p["x"], "z": c.p["z"]}, {"x": aim.x, "z": aim.z})
	var to := Vector3(m["x"], TARGET_Y, m["z"])
	var tip := c.tip()
	c.after(tip.distance_to(to) / SPEED * 1000.0, func() -> void: _land(c, m))
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": tip, "to": to, "speed": SPEED, "arc": ARC})
	return ""


## A friendly Withered cloud (also what a toxic Corpse Explosion leaves: sim kind "rot", same rules). Host.
func add_zone(c: DmRiteCaster, x: float, z: float, r: float, dps: float, duration_ms: float, cap: float) -> void:
	var zones: Array = c.mem(id).get_or_add("zones", [])
	zones.append({"x": x, "z": z, "r": r, "dps": dps, "until": c.now_ms + duration_ms, "tick": 0.0, "scan": 0.0, "cap": cap})


func _land(c: DmRiteCaster, m: Dictionary) -> void:
	add_zone(c, float(m["x"]), float(m["z"]), float(m["r"]), float(m["dps"]), float(m["durationMs"]), float(m["witheredCap"]))
	c.broadcast({"t": "land", "rite": id, "by": c.peer_id, "x": float(m["x"]), "z": float(m["z"]), "r": float(m["r"])})


## The cloud, sim_zones.update_zones for a friendly miasma: every 1 s pulse each enemy inside gets +1 Withered stack (capped) and the
## strongest dps; enemies inside are slowed (MIASMA_SLOW) while they stand in it.
func step(c: DmRiteCaster, dt: float) -> void:
	var zones: Array = c.mem(id).get("zones", [])
	var i := 0
	while i < zones.size():
		var z: Dictionary = zones[i]
		if c.now_ms >= float(z["until"]):
			zones.remove_at(i)
			continue
		i += 1
		z["tick"] = float(z["tick"]) - dt
		var pulse: bool = z["tick"] <= 0.0
		if pulse:
			z["tick"] = 1.0
		z["scan"] = float(z["scan"]) - dt
		if z["scan"] > 0.0 and not pulse:
			continue
		z["scan"] = SCAN_S
		for n in c.world.enemies_in_radius(Vector3(z["x"], 0.0, z["z"]), float(z["r"]) + 2.0):
			var e := n as Node3D
			if e == null or not DmRiteCaster.alive_enemy(e):
				continue
			var gp := e.global_position
			if Vector2(gp.x - float(z["x"]), gp.z - float(z["z"])).length() > float(z["r"]) + float(e.get("radius")):
				continue
			var ss := DmStatusSet.ensure(e)
			c.watch_dots(ss)
			ss.apply(&"slow", c.body, 1, SLOW_HOLD_S)
			if e.has_meta(&"dm_shrouded"):
				e.set_meta(&"dm_miasma_ms", Time.get_ticks_msec())   # lifts the Shrouded affix's ward while it stands in the cloud
			if pulse:
				ss.apply(&"withered", c.body, 1, -1.0, {"dps": float(z["dps"]), "cap": float(z["cap"])})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"cast":
			c.fx.shot(ev["from"], ev["to"], float(ev["speed"]), float(ev["arc"]), "orb", DmFxData.spell("miasma", "rot"))
		"land":
			c.fx.miasma_land(float(ev["x"]), float(ev["z"]), float(ev["r"]))
