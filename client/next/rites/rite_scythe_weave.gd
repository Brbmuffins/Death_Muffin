extends DmRiteModule
## Scythe Weave (the Reaper, Grimoire): her quick single-target strike. Each cast hits the nearest enemy in a narrow 3.6 m cone toward the cursor for power 0.7,
## and the strokes alternate: an overhead chop (the scythe drops from above onto the target), then a rising cut (up from the ground through it). Free, 0.45 s: on a
## held hotbar key the hold repeat (DmCombatInput) strikes again the moment it is ready. Every hit leeches. `p["weaveStroke"]` is the stroke just thrown
## (0 chop, 1 rise); the gesture (DmRiteCaster._gesture_cast) reads it to pick the matching clip.
## On the combat core (client/code.list "Ported"): the target is a DmFoe snapshot (DmReaperRites.cone).

const HALF_DEG := 35.0   ## either side of the aim line
const HIGH := 2.9        ## m: where a chop starts above the target / where a rising cut ends


func _init() -> void:
	id = "scythe_weave"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	return "no_target" if DmReaperRites.facing(c, intent["aim"]) == Vector2.ZERO else ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var dir := DmReaperRites.facing(c, intent["aim"])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var stroke := 1 - int(c.p.get("weaveStroke", 1))
	c.p["weaveStroke"] = stroke
	var origin := c.pos()
	var reach := float(DmAbilities.def(id)["radius"])
	var best: DmFoe = null
	var best_d := INF
	for e: DmFoe in DmReaperRites.cone(c, origin.x, origin.z, dir.x, dir.y, reach, HALF_DEG):
		var d := Vector2(e.x - origin.x, e.z - origin.z).length_squared()
		if d < best_d:
			best_d = d
			best = e
	var targets: Array = [] if best == null else [best]
	var marks := DmReaperRites.strike(c, id, targets, dmg, true)
	c.broadcast({"t": "weave", "rite": id, "by": c.peer_id, "x": origin.x, "z": origin.z, "dx": dir.x, "dz": dir.y, "reach": reach, "stroke": stroke, "hits": marks, "amount": dmg})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var hits := ev["hits"] as Array
	var dx := float(ev["dx"])
	var dz := float(ev["dz"])
	var tx: float
	var tz: float
	if hits.is_empty():   # a swing at the air, two metres out
		tx = float(ev["x"]) + dx * 2.0
		tz = float(ev["z"]) + dz * 2.0
	else:
		tx = (hits[0] as Vector3).x
		tz = (hits[0] as Vector3).z
	var a: Vector3
	var b: Vector3
	if int(ev["stroke"]) == 0:   # chop: from above and behind the target down to the ground in front of it
		a = Vector3(tx - dx * 0.5, HIGH, tz - dz * 0.5)
		b = Vector3(tx + dx * 0.2, 0.1, tz + dz * 0.2)
	else:                        # rise: up from the ground on her side of the target to above and past it
		a = Vector3(tx - dx * 0.6, 0.1, tz - dz * 0.6)
		b = Vector3(tx + dx * 0.5, HIGH, tz + dz * 0.5)
	c.fx.beam(a, func() -> Vector3: return b, DmReaperRites.GREEN, 0.34, 0.2)
	c.fx.beam(a, func() -> Vector3: return b, DmReaperRites.PALE, 0.14, 0.14)
	c.fx.lf(tx, 1.2, tz, DmReaperRites.GREEN, 10.0, 0.15)
	c.fx.sfx("ivoryCleave", float(ev["x"]), float(ev["z"]), 0.9)
	DmReaperRites._hits(c, ev)
	if not hits.is_empty():
		if int(ev["stroke"]) == 0:   # the chop lands on the ground: a small ring
			c.fx.decal("ring", DmReaperRites.GREEN, tx, tz, 1.1, 0.3, 0.8, {"growFrom": 0.3, "fadeOut": 0.2})
		c.shake_requested.emit(0.02)
