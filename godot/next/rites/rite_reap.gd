extends DmRiteModule
## Reap (the Reaper, key 3rd of her kit): a huge cone toward the cursor, 150 degrees and 6.5 m, power 2.4, 35 energy, 6 s. It spends up to 10 souls from
## the soul bag, each adding 12% damage on top of the bag's own +2% a soul (the bag is read before it is spent). Resolved at once.


func _init() -> void:
	id = "reap"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	return "no_target" if DmReaperRites.facing(c, intent["aim"]) == Vector2.ZERO else ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var K := DmReaperRites.k()
	var dir := DmReaperRites.facing(c, intent["aim"])
	var origin := c.pos()
	var reach := float(DmAbilities.def(id)["range"])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var spent := DmPlayerRules.bag_spend(c.p, int(K["reapSoulsMax"]))
	dmg *= 1.0 + float(K["reapPerSoul"]) * float(spent)
	var marks := DmReaperRites.strike(c, id, DmReaperRites.cone(c, origin.x, origin.z, dir.x, dir.y, reach, float(K["reapHalfAngleDeg"])), dmg)
	c.broadcast({"t": "reap", "rite": id, "by": c.peer_id, "x": origin.x, "z": origin.z, "dx": dir.x, "dz": dir.y, "reach": reach, "hits": marks, "amount": dmg, "souls": spent})
	c.push_state()
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	DmReaperRites.draw_sweep(c, ev, 1.25)
	var x := float(ev["x"])
	var z := float(ev["z"])
	if int(ev["souls"]) > 0:   # the spent souls flare off the blade
		c.fx.emit(x + float(ev["dx"]) * 2.0, 1.0, z + float(ev["dz"]) * 2.0, 6 + 2 * int(ev["souls"]), DmReaperRites.PALE, 0.8, 3.0, 1.6, 0.6, 0.16, {"gravity": 1.0})
	c.shake_requested.emit(0.07)
