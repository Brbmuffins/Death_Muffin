extends DmRiteModule
## Rot Lance, an LMB primary (level 6): a lance of rot flies 32 m/s down the line toward the target (range 14, free, 700 ms, power 0.8) and on arrival
## pierces the first 2 enemies in a 0.25 m half-width lane, +1 Withered stack each (cap from the discipline, Chain Plague lifts it), +4 essence once.
## Numbers: DmAbilities + ROT_LANCE + WITHERED (dps per stack x the blow); visuals: DmRiteFx.lance_cast / lance_hit.
## On the combat core (client/code.list "Ported"): enemies are ids and DmFoe snapshots, the blow is `c.deal` (a kill is known at once), statuses are the core's (`c.apply_status`).

const TARGET_Y := 1.0


func _init() -> void:
	id = "rot_lance"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var foe := pick_enemy(c, intent["aim"], int(intent["target_id"]))
	if foe == null:
		return "no_target"
	if DmAbilities.shortfall(c.p, id, {"x": foe.x, "z": foe.z}, DmSimConsts.BOSS_RADIUS) > 0.0:
		return "range"
	intent["foe"] = foe
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var RL: Dictionary = DmCombatData.const_table("ROT_LANCE")
	var rng_m := float(DmAbilities.def(id)["range"])
	var origin := c.pos()
	var foe: DmFoe = intent["foe"]
	var dx := foe.x - origin.x
	var dz := foe.z - origin.z
	var l := Vector2(dx, dz).length()
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	var tip := c.tip()
	var end := Vector3(origin.x + dx * rng_m, TARGET_Y, origin.z + dz * rng_m)
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var cap := DmLegend.effective_withered_cap(c.mods)
	c.after(tip.distance_to(end) / float(RL["speed"]) * 1000.0, func() -> void: _arrive(c, origin, dx, dz, dmg, cap))
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": tip, "to": end, "speed": float(RL["speed"])})
	return ""


func _arrive(c: DmRiteCaster, origin: Vector3, dx: float, dz: float, dmg: float, cap: float) -> void:
	var RL: Dictionary = DmCombatData.const_table("ROT_LANCE")
	var row := lane(c, origin.x, origin.z, dx, dz, float(DmAbilities.def(id)["range"]), float(RL["halfWidth"]), true)
	var hits: Array = []
	var dps := dmg * float(DmSimData.WITHERED["dpsPerStack"])
	var stack_cap := minf(12.0, maxf(1.0, floorf(cap)))
	for i in mini(row.size(), int(RL["pierce"])):
		var e: DmFoe = row[i]["e"]
		var r := c.deal(e.id, dmg)
		if float(r["dealt"]) <= 0.0:
			continue
		c.apply_status(e.id, &"withered", int(RL["withered"]), -1.0, {"dps": dps, "cap": stack_cap})
		hits.append(Vector3(e.x, TARGET_Y, e.z))
		c.hit_resolved.emit(id, e.id, dmg, false, bool(r["killed"]))
	if hits.is_empty():
		return
	c.gain_essence(float(RL["essence"]))
	c.broadcast({"t": "hit", "rite": id, "by": c.peer_id, "hits": hits, "amount": dmg})
	c.push_state()


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"cast":
			var from: Vector3 = ev["from"]
			var to: Vector3 = ev["to"]
			c.fx.lance_cast(from, to, from.x, from.z)
			c.fx.shot(from, to, float(ev["speed"]), 0.0, "orb", DmFxData.spell("lance", "rot"))
		"hit":
			c.fx.lance_hit(ev["hits"])
			for h: Vector3 in ev["hits"]:
				c.hit_number.emit(h, float(ev["amount"]), false)
