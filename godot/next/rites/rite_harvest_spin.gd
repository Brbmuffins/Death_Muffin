extends DmRiteModule
## Harvest Spin (the Reaper's right-click): a full circle around her, 4 m, power 1.1, 16 energy, 3.5 s. Resolved at once.


func _init() -> void:
	id = "harvest_spin"


func resolve(c: DmRiteCaster, _intent: Dictionary) -> String:
	var origin := c.pos()
	var r := float(DmAbilities.def(id)["radius"])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var marks := DmReaperRites.strike(c, id, DmReaperRites.cone(c, origin.x, origin.z, 0.0, 1.0, r, 180.0), dmg)
	c.broadcast({"t": "spin", "rite": id, "by": c.peer_id, "x": origin.x, "z": origin.z, "r": r, "hits": marks, "amount": dmg})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	DmReaperRites.draw_circle(c, ev)
	if not (ev["hits"] as Array).is_empty():
		c.shake_requested.emit(0.04)
