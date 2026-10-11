extends DmRiteModule
## Scythe Throw (the Reaper): the scythe is hurled to the cursor (ground, clamped to 12 m) and spins there for 2 s, hitting everything within 2.6 m (+ the
## enemy's radius) every 0.25 s for power 0.45 each. 22 energy, 7 s. Host: `mem("scythe_throw").spins` (the damage is rolled once, at the throw); every
## peer draws the ring from the cast event and a spray from each tick that struck something.


func _init() -> void:
	id = "scythe_throw"
	steps = true


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var K := DmReaperRites.k()
	var def := DmAbilities.def(id)
	var at := DmRiteModule.clamp_reach(c.pos(), intent["aim"], float(def["range"]))
	var m := c.mem(id)
	var spins: Array = m.get_or_add("spins", [])
	spins.append({"x": at.x, "z": at.z, "r": float(def["radius"]), "dmg": DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id),
		"until": c.now_ms + float(K["throwLifeS"]) * 1000.0, "next": c.now_ms + float(K["throwTickS"]) * 1000.0})
	c.broadcast({"t": "throw", "rite": id, "by": c.peer_id, "ox": c.pos().x, "oz": c.pos().z, "x": at.x, "z": at.z, "r": float(def["radius"]), "life": float(K["throwLifeS"])})
	return ""


func step(c: DmRiteCaster, _dt: float) -> void:
	var spins: Array = c.mem(id).get("spins", [])
	var i := spins.size() - 1
	while i >= 0:
		var s: Dictionary = spins[i]
		if not bool(c.p["alive"]) or c.now_ms >= float(s["until"]):
			spins.remove_at(i)
		elif c.now_ms >= float(s["next"]):
			s["next"] = float(s["next"]) + float(DmReaperRites.k()["throwTickS"]) * 1000.0
			var marks := DmReaperRites.strike(c, id, DmReaperRites.cone(c, float(s["x"]), float(s["z"]), 0.0, 1.0, float(s["r"]), 180.0), float(s["dmg"]))
			if not marks.is_empty():
				c.broadcast({"t": "tick", "rite": id, "by": c.peer_id, "x": float(s["x"]), "z": float(s["z"]), "r": float(s["r"]), "hits": marks, "amount": float(s["dmg"])})
				c.push_state()
		i -= 1


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var x := float(ev["x"])
	var z := float(ev["z"])
	if String(ev["t"]) == "throw":
		var r := float(ev["r"])
		var life := float(ev["life"])
		c.fx.decal("ring", DmReaperRites.GREEN, x, z, r, life, 0.55, {"spin": 7.0, "fadeOut": 0.4})
		c.fx.decal("crescent", DmReaperRites.PALE, x, z, r * 0.8, life, 0.8, {"spin": 14.0, "fadeOut": 0.3})
		c.fx.smoke(x, 0.5, z, 5, DmReaperRites.DEEP, r * 0.5, 1.0, 1.0, 0.8, 1.0, {"shrink": -0.4})
		c.fx.lf(x, 1.2, z, DmReaperRites.GREEN, 16.0, 0.3)
		c.fx.sfx("storm", x, z, 0.9)
		c.shake_requested.emit(0.03)
		return
	for h: Vector3 in ev["hits"]:
		c.fx.emit(h.x, 0.9, h.z, 3, DmReaperRites.GREEN, 0.2, 2.2, 1.0, 0.3, 0.1, {"gravity": 8.0})
		c.hit_number.emit(h, float(ev["amount"]), false)
	c.fx.sfx("boneHit", x, z, 0.8)
