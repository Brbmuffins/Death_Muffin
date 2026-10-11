extends DmRiteModule
## Scythe Sweep (the Reaper's primary): a 130 degree arc, 3.4 m, toward the cursor or the enemy clicked, resolved at once. Free, 0.6 s, power 0.9.
## Numbers: DmAbilities + REAPER.sweepHalfAngleDeg; visuals: DmReaperRites.draw_sweep.


func _init() -> void:
	id = "scythe_sweep"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	return "no_target" if DmReaperRites.facing(c, intent["aim"]) == Vector2.ZERO else ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var dir := DmReaperRites.facing(c, intent["aim"])
	var origin := c.pos()
	var reach := float(DmAbilities.def(id)["range"])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var marks := DmReaperRites.strike(c, id, DmReaperRites.cone(c, origin.x, origin.z, dir.x, dir.y, reach, float(DmReaperRites.k()["sweepHalfAngleDeg"])), dmg)
	c.broadcast({"t": "sweep", "rite": id, "by": c.peer_id, "x": origin.x, "z": origin.z, "dx": dir.x, "dz": dir.y, "reach": reach, "hits": marks, "amount": dmg})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	DmReaperRites.draw_sweep(c, ev)
	if not (ev["hits"] as Array).is_empty():
		c.shake_requested.emit(0.03)
