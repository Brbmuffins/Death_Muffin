extends DmRiteModule
## Wailing Skull (grimoire, level 3): a skull flies 15 m/s at the enemy nearest the cursor (picked within 4 m of it, range 13, 16 essence, 3 s, power 2.4),
## then leaps to the nearest enemy not yet struck within 6.5 m, each leap x0.8 weaker. 3 leaps; a leap that kills earns another; never past 5 in all.
## Numbers: DmAbilities + WAILING_SKULL; every leap is a broadcast event (the skull is a visual `shot` per leap), the blow lands on the host on arrival.
## Visuals: DmRiteFx.skull_cast / skull_leap / skull_hit. A boss is a foe like any (the host's queries append it after the enemies).
## On the combat core (client/code.list "Ported"): the blow is `c.deal` and its `killed` is known at once, so a leap that kills earns the extra leap as today.

const Y := 1.1


func _init() -> void:
	id = "wailing_skull"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var foe := pick_enemy(c, intent["aim"], int(intent["target_id"]), float(DmAbilities.def(id)["radius"]))
	if foe == null:
		return "no_target"
	if DmAbilities.shortfall(c.p, id, {"x": foe.x, "z": foe.z}, DmSimConsts.BOSS_RADIUS) > 0.0:
		return "range"
	intent["foe"] = foe
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var W: Dictionary = DmCombatData.const_table("WAILING_SKULL")
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	_leap(c, c.tip(), intent["foe"] as DmFoe, dmg, 1, int(W["hops"]), {})
	return ""


## One flight toward `e`. `budget` = leaps left including this one.
func _leap(c: DmRiteCaster, from: Vector3, e: DmFoe, dmg: float, hop: int, budget: int, struck: Dictionary) -> void:
	var W: Dictionary = DmCombatData.const_table("WAILING_SKULL")
	var eid := e.id
	var to := Vector3(e.x, Y, e.z)
	c.after(from.distance_to(to) / float(W["speed"]) * 1000.0, func() -> void: _arrive(c, eid, to, dmg, hop, budget, struck))
	c.broadcast({"t": "leap", "rite": id, "by": c.peer_id, "from": from, "to": to, "enemy_id": eid, "speed": float(W["speed"]), "first": hop == 1})


func _arrive(c: DmRiteCaster, eid: int, last: Vector3, dmg: float, hop: int, budget: int, struck: Dictionary) -> void:
	var W: Dictionary = DmCombatData.const_table("WAILING_SKULL")
	var e := c.foe(eid)
	var pos := last
	var landed := false
	var killed := false
	if e != null:
		pos = Vector3(e.x, Y, e.z)
		var r := c.deal(eid, dmg)
		landed = float(r["dealt"]) > 0.0
		killed = landed and bool(r["killed"])
		if landed:
			c.hit_resolved.emit(id, eid, dmg, false, killed)
	struck[eid] = true
	var left := budget - 1 + (1 if killed else 0)
	var nxt: DmFoe = null
	if left > 0 and hop < int(W["maxHops"]):
		var best_d := float(W["leapRange"])
		for o in c.foes_in_radius(pos, best_d):
			if struck.has(o.id):
				continue
			var d := Vector2(o.x - pos.x, o.z - pos.z).length()
			if d < best_d:
				best_d = d
				nxt = o
	if landed:
		c.broadcast({"t": "hit", "rite": id, "by": c.peer_id, "pos": pos, "amount": dmg, "killed": killed, "more": nxt != null})
		c.push_state()
	if nxt != null:
		_leap(c, pos, nxt, dmg * float(W["falloff"]), hop + 1, left, struck)


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"leap":
			var from: Vector3 = ev["from"]
			if bool(ev["first"]):
				c.fx.skull_cast(from, from.x, from.z)
			c.fx.skull_leap(from, follow_enemy(c, int(ev["enemy_id"]), ev["to"], Y), float(ev["speed"]))
		"hit":
			var pos: Vector3 = ev["pos"]
			c.fx.skull_hit(pos, bool(ev["killed"]), bool(ev["more"]))
			c.hit_number.emit(pos, float(ev["amount"]), bool(ev["killed"]))
