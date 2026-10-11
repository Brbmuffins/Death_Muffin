class_name DmReaperRites
extends RefCounted
## What the Reaper's rites share (scythe_sweep, harvest_spin, reap, soul_burst, scythe_throw, wraith_walk): the cone / circle target pick, the dealing of
## one blow to every target with its hit marks, the soul bag, and the green visuals. Numbers: the REAPER constants (abilities.json) + DmAbilities.

const GREEN := Color("6ee7a0")   ## the Reaper's colour: souls and her energy
const DEEP := Color("1f7a52")
const PALE := Color("c8ffe0")
const MAX_TARGETS := 64
const SHOWN := 10                ## hit marks in an event (the sim floats at most 10 numbers)


static func k() -> Dictionary:
	return DmCombatData.const_table("REAPER")


## HOST. Living, hittable enemies whose edge lies inside the cone from (ox, oz) along the unit direction (dx, dz): out to `reach`, within `half_deg`
## either side. half_deg >= 180 is a full circle. At most MAX_TARGETS.
static func cone(c: DmRiteCaster, ox: float, oz: float, dx: float, dz: float, reach: float, half_deg: float) -> Array:
	var out: Array = []
	var cos_max := cos(deg_to_rad(half_deg))
	for e: DmEnemy in c.world.enemies_in_radius(Vector3(ox, 0.0, oz), reach + 3.0):
		if e == null or not DmRiteCaster.alive_enemy(e) or not e.is_hittable():
			continue
		var rx := e.global_position.x - ox
		var rz := e.global_position.z - oz
		var d := sqrt(rx * rx + rz * rz)
		if d > reach + e.radius:
			continue
		if half_deg < 180.0 and d >= e.radius and (rx * dx + rz * dz) / d < cos_max:
			continue
		out.append(e)
		if out.size() >= MAX_TARGETS:
			break
	return out


## HOST. One blow of `dmg` to each target (kill credit to the caster); returns the hit marks to put in the event (at most SHOWN).
static func strike(c: DmRiteCaster, rite: String, targets: Array, dmg: float) -> Array:
	var marks: Array = []
	for e: DmEnemy in targets:
		if not DmStatusSet.hit(e, dmg, c.body):
			continue
		c.hit_resolved.emit(rite, int(c.world.enemy_id(e)), dmg, false, float(e.get("hp")) <= 0.0)
		if marks.size() < SHOWN:
			marks.append(Vector3(e.global_position.x, 0.9, e.global_position.z))
	return marks


## HOST. The unit direction from the caster to `aim`, or Vector2.ZERO when the cursor sits on her.
static func facing(c: DmRiteCaster, aim: Vector3) -> Vector2:
	var d := Vector2(aim.x - float(c.p["x"]), aim.z - float(c.p["z"]))
	return d.normalized() if d.length() > 1e-4 else Vector2.ZERO


# ---- every peer: visuals ---------------------------------------------------------------------------------------------------------------------

## The crescent of a swing and a green spray on each struck enemy; `ev` = {x, z, dx, dz, reach, hits, amount}. Returns nothing: the caller shakes.
static func draw_sweep(c: DmRiteCaster, ev: Dictionary, size: float = 1.0) -> void:
	var x := float(ev["x"])
	var z := float(ev["z"])
	var dx := float(ev["dx"])
	var dz := float(ev["dz"])
	var reach := float(ev["reach"])
	var rot := atan2(dx, dz)
	var mid := reach * 0.42
	c.fx.decal("crescent", GREEN, x + dx * mid, z + dz * mid, reach * 0.62 * size, 0.42, 1.0, {"rot": rot, "growFrom": 0.6, "fadeOut": 0.3})
	c.fx.decal("crescent", PALE, x + dx * (mid + 0.1), z + dz * (mid + 0.1), reach * 0.66 * size, 0.3, 0.55, {"rot": rot, "growFrom": 0.7})
	c.fx.lf(x + dx * mid, 1.0, z + dz * mid, GREEN, 12.0, 0.2)
	c.fx.sfx("ivoryCleave", x, z, 1.1)
	_hits(c, ev)


## A full-circle swing around (x, z): a ring that opens to `r`.
static func draw_circle(c: DmRiteCaster, ev: Dictionary) -> void:
	var x := float(ev["x"])
	var z := float(ev["z"])
	var r := float(ev["r"])
	c.fx.decal("ring", GREEN, x, z, r, 0.45, 0.9, {"growFrom": 0.3, "fadeOut": 0.3})
	c.fx.decal("ring", PALE, x, z, r * 0.7, 0.3, 0.5, {"growFrom": 0.2, "spin": 6.0})
	c.fx.smoke(x, 0.4, z, 4, DEEP, r * 0.5, 1.2, 0.8, 0.6, 0.9, {"shrink": -0.4})
	c.fx.lf(x, 1.0, z, GREEN, 14.0, 0.22)
	c.fx.sfx("ivoryCleave", x, z, 1.2)
	_hits(c, ev)


static func _hits(c: DmRiteCaster, ev: Dictionary) -> void:
	for h: Vector3 in ev["hits"]:
		c.fx.emit(h.x, 0.9, h.z, 5, GREEN, 0.2, 2.4, 1.1, 0.35, 0.12, {"gravity": 8.0})
		c.hit_number.emit(h, float(ev["amount"]), false)
	if not (ev["hits"] as Array).is_empty():
		c.fx.sfx("boneHit", float(ev["x"]), float(ev["z"]))
