extends DmRiteModule
## Soul Burst (the Reaper): empties the whole soul bag in a blast around her, 6 m, power 1.2, 20 energy, 10 s. Each soul adds 18% damage on top of the
## bag's own +2% a soul (read before it is spent); an empty bag still hits for the base blow. Resolved at once.


func _init() -> void:
	id = "soul_burst"


func resolve(c: DmRiteCaster, _intent: Dictionary) -> String:
	var origin := c.pos()
	var r := float(DmAbilities.def(id)["radius"])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var spent := DmPlayerRules.bag_spend(c.p, int(c.p["souls"]))
	dmg *= 1.0 + float(DmReaperRites.k()["burstPerSoul"]) * float(spent)
	var marks := DmReaperRites.strike(c, id, DmReaperRites.cone(c, origin.x, origin.z, 0.0, 1.0, r, 180.0), dmg)
	c.broadcast({"t": "burst", "rite": id, "by": c.peer_id, "x": origin.x, "z": origin.z, "r": r, "hits": marks, "amount": dmg, "souls": spent})
	c.push_state()
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	DmReaperRites.draw_circle(c, ev)
	var x := float(ev["x"])
	var z := float(ev["z"])
	c.fx.emit(x, 1.0, z, 10 + 3 * int(ev["souls"]), DmReaperRites.PALE, float(ev["r"]) * 0.5, 4.0, 2.0, 0.8, 0.18, {"gravity": 0.5})
	c.fx.sfx("wail", x, z, 0.8)
	c.shake_requested.emit(0.06 + 0.002 * float(ev["souls"]))
