extends DmRiteModule
## Haunting Wraith (the Reaper, Grimoire only): a huge wraith rises at her feet and walks `range` (14 m) toward the cursor at `speed` (6 m/s: 2.3 s), hurting every enemy it
## touches (`radius` 2.2 m round it, plus the enemy's radius) every 0.25 s for `power` 0.5. 5 souls, 14 s. The numbers are the rite's row in data/combat/abilities.json. Host: `mem("haunting_wraith").walkers`
## (the damage is rolled once, at the cast); every peer draws the wraith from the cast event (its ghost model, `DmWraithGhost`) and from each tick's event.
## On the combat core: the wraith's targets are DmFoe snapshots from `DmReaperRites.cone`, a blow is `c.deal` (through `DmReaperRites.strike`).

const TICK_S := 0.25    ## damage and drawing step


func _init() -> void:
	id = "haunting_wraith"
	steps = true


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	return "no_target" if DmReaperRites.facing(c, intent["aim"]) == Vector2.ZERO else ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var dir := DmReaperRites.facing(c, intent["aim"])
	var from := c.pos()
	var def := DmAbilities.def(id)
	var walkers: Array = c.mem(id).get_or_add("walkers", [])
	var speed := float(def["speed"])
	walkers.append({"x": from.x, "z": from.z, "dx": dir.x, "dz": dir.y, "r": float(def["radius"]), "speed": speed,
		"dmg": DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id),
		"until": c.now_ms + float(def["range"]) / speed * 1000.0, "next": c.now_ms + TICK_S * 1000.0})
	c.broadcast({"t": "rise", "rite": id, "by": c.peer_id, "x": from.x, "z": from.z, "r": float(def["radius"]),
		"dx": dir.x, "dz": dir.y, "speed": speed, "life": float(def["range"]) / speed})
	return ""


func step(c: DmRiteCaster, dt: float) -> void:
	var walkers: Array = c.mem(id).get("walkers", [])
	var i := walkers.size() - 1
	while i >= 0:
		var w: Dictionary = walkers[i]
		if not bool(c.p["alive"]) or c.now_ms >= float(w["until"]):
			walkers.remove_at(i)
		else:
			w["x"] = float(w["x"]) + float(w["dx"]) * float(w["speed"]) * dt
			w["z"] = float(w["z"]) + float(w["dz"]) * float(w["speed"]) * dt
			if c.now_ms >= float(w["next"]):
				w["next"] = float(w["next"]) + TICK_S * 1000.0
				var marks := DmReaperRites.strike(c, id, DmReaperRites.cone(c, float(w["x"]), float(w["z"]), 0.0, 1.0, float(w["r"]), 180.0), float(w["dmg"]), false)
				c.broadcast({"t": "walk", "rite": id, "by": c.peer_id, "x": float(w["x"]), "z": float(w["z"]), "r": float(w["r"]), "hits": marks, "amount": float(w["dmg"])})
				if not marks.is_empty():
					c.push_state()
		i -= 1


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var x := float(ev["x"])
	var z := float(ev["z"])
	var r := float(ev["r"])
	if String(ev["t"]) == "rise":
		c.fx.decal("ring", DmReaperRites.GREEN, x, z, r * 1.6, 0.6, 0.9, {"growFrom": 0.3, "fadeOut": 0.4})
		c.fx.smoke(x, 1.0, z, 4, DmReaperRites.DEEP, r * 0.8, 1.4, 0.9, 1.0, 1.2, {"shrink": -0.4})
		c.fx.lf(x, 1.5, z, DmReaperRites.GREEN, 16.0, 0.3)
		c.fx.sfx("wail", x, z, 1.0)
		c.fx.sfx("banshee", x, z, 1.0)
		c.shake_requested.emit(0.04)
		DmWraithGhost.spawn(c, x, z, float(ev["dx"]), float(ev["dz"]), float(ev["speed"]), float(ev["life"]), "WraithGhost%d" % c.get_child_count())
		return
	# The wraith itself is the ghost model (see `rise`); here a wisp of smoke trailing it, a glow and a ring on the ground under it.
	c.fx.smoke(x, 1.6, z, 2, DmReaperRites.DEEP, r * 0.6, 1.6, 0.9, 1.0, 1.2, {"shrink": -0.4})
	c.fx.decal("ring", DmReaperRites.GREEN, x, z, r, 0.3, 0.7, {"fadeOut": 0.2})
	c.fx.lf(x, 2.0, z, DmReaperRites.GREEN, 18.0, 0.3)
	for h: Vector3 in ev["hits"]:
		c.fx.emit(h.x, 0.9, h.z, 4, DmReaperRites.GREEN, 0.25, 2.2, 1.0, 0.4, 0.1, {"gravity": 6.0})
		c.hit_number.emit(h, float(ev["amount"]), false)
	if not (ev["hits"] as Array).is_empty():
		c.fx.sfx("boneHit", x, z, 0.8)
