extends DmRiteModule
## Soul Harvest (the Reaper, Grimoire): leeches every living enemy within 9 m, power 0.5, free, 5 s. Each enemy struck puts 1 soul in the bag (up to its size) and
## heals her harvestHealPerMob of her max health, at most harvestHealCap a cast. Resolved at once.


func _init() -> void:
	id = "soul_harvest"


func resolve(c: DmRiteCaster, _intent: Dictionary) -> String:
	var origin := c.pos()
	var r := float(DmAbilities.def(id)["radius"])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var targets := DmReaperRites.cone(c, origin.x, origin.z, 0.0, 1.0, r, 180.0)
	var count := []
	var marks := DmReaperRites.strike(c, id, targets, dmg, false, count)
	var struck: int = count[0]
	var K := DmReaperRites.k()
	if struck > 0:
		DmPlayerRules.bag_add(c.p, struck)
		c.heal(float(c.p["stats"]["maxHp"]) * minf(float(K["harvestHealPerMob"]) * float(struck), float(K["harvestHealCap"])))
		c.push_state()
	c.broadcast({"t": "harvest", "rite": id, "by": c.peer_id, "x": origin.x, "z": origin.z, "r": r, "hits": marks, "amount": dmg})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	DmReaperRites.draw_circle(c, ev)
	c.fx.sfx("wail", float(ev["x"]), float(ev["z"]), 0.6)
	if not (ev["hits"] as Array).is_empty():
		c.shake_requested.emit(0.03)
