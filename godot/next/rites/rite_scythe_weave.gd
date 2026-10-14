extends DmRiteModule
## Scythe Weave (the Reaper, Grimoire): the scythe turned like a quarterstaff, a figure of eight across the 180 degrees in front of her. Two passes, 0.35 s apart
## (the first from the left, the second back from the right), each a 4.4 m half-circle toward the cursor that strikes everything in it for power 0.8; what stands
## in the middle is caught by both. Free, 0.9 s: on a held hotbar key the hold repeat (DmCombatInput) weaves again the moment it is ready. Only the first pass leeches.

const PASS_GAP_MS := 350.0
const TURN := 0.6   ## rad: how far each lobe's crescent is drawn off the aim line (the hit area is the whole half-circle)


func _init() -> void:
	id = "scythe_weave"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	return "no_target" if DmReaperRites.facing(c, intent["aim"]) == Vector2.ZERO else ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var dir := DmReaperRites.facing(c, intent["aim"])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	_pass(c, dir, dmg, 1.0, true)
	c.after(PASS_GAP_MS, func() -> void: _pass(c, dir, dmg, -1.0, false))
	return ""


func _pass(c: DmRiteCaster, dir: Vector2, dmg: float, side: float, leech: bool) -> void:
	var origin := c.pos()
	var reach := float(DmAbilities.def(id)["radius"])
	var marks := DmReaperRites.strike(c, id, DmReaperRites.cone(c, origin.x, origin.z, dir.x, dir.y, reach, 90.0), dmg, leech)
	c.broadcast({"t": "weave", "rite": id, "by": c.peer_id, "x": origin.x, "z": origin.z, "dx": dir.x, "dz": dir.y, "reach": reach, "side": side, "hits": marks, "amount": dmg})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var d := Vector2(float(ev["dx"]), float(ev["dz"])).rotated(float(ev["side"]) * TURN)
	var drawn := ev.duplicate()
	drawn["dx"] = d.x
	drawn["dz"] = d.y
	DmReaperRites.draw_sweep(c, drawn, 1.3)
	if not (ev["hits"] as Array).is_empty():
		c.shake_requested.emit(0.03)
