extends DmRiteModule
## Ivory Cleave (grimoire, level 4): a 120 degree crescent (half-angle 60, reach 3.6 + the enemy's radius) toward the cursor, resolved at once: power 1.7,
## +1 Fracture on everything it cuts (capped at 64 targets), 14 essence, 1.6 s. Numbers: DmAbilities + IVORY_CLEAVE; visuals: DmRiteFx.cleave.

const MAX_TARGETS := 64
const SHOWN := 10   ## hit marks in the event (the sim floats at most 10 numbers)


func _init() -> void:
	id = "ivory_cleave"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var aim: Vector3 = intent["aim"]
	return "no_target" if Vector2(aim.x - float(c.p["x"]), aim.z - float(c.p["z"])).length() < 1e-4 else ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var IC: Dictionary = DmCombatData.const_table("IVORY_CLEAVE")
	var aim: Vector3 = intent["aim"]
	var origin := c.pos()
	var dx := aim.x - origin.x
	var dz := aim.z - origin.z
	var l := Vector2(dx, dz).length()
	dx /= l
	dz /= l
	var reach := float(IC["reach"])
	var cos_max := cos(deg_to_rad(float(IC["halfAngleDeg"])))
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var pos: Array = []
	var n_hit := 0
	for n in c.world.enemies_in_radius(origin, reach + 3.0):
		var e := n as Node3D
		if e == null or not DmRiteCaster.alive_enemy(e) or not _in_arc(e, origin, reach, dx, dz, cos_max):
			continue
		if not DmStatusSet.hit(e, dmg, c.body):
			continue
		var ss := DmStatusSet.ensure(e)
		c.watch_dots(ss)
		ss.apply(&"fracture", c.body, int(IC["fracture"]))
		if pos.size() < SHOWN:
			pos.append(Vector3(e.global_position.x, 0.9, e.global_position.z))
		c.hit_resolved.emit(id, int(c.world.enemy_id(e)), dmg, false, float(e.get("hp")) <= 0.0)
		n_hit += 1
		if n_hit >= MAX_TARGETS:
			break
	c.broadcast({"t": "cleave", "rite": id, "by": c.peer_id, "x": origin.x, "z": origin.z, "dx": dx, "dz": dz, "hits": pos, "amount": dmg})
	if n_hit > 0:
		c.push_state()
	return ""


static func _in_arc(e: Node3D, origin: Vector3, reach: float, dx: float, dz: float, cos_max: float) -> bool:
	var rx := e.global_position.x - origin.x
	var rz := e.global_position.z - origin.z
	var d := Vector2(rx, rz).length()
	var r := float(e.get("radius"))
	if d > reach + r:
		return false
	return d < r or (rx * dx + rz * dz) / d >= cos_max


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	c.shake_requested.emit(c.fx.cleave(ev))
	for h: Vector3 in ev["hits"]:
		c.hit_number.emit(h, float(ev["amount"]), false)
