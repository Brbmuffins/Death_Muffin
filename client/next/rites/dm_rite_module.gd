class_name DmRiteModule
extends RefCounted
## One rite of the DmRiteCaster. A module is a shared, stateless singleton (see DmRiteRegistry): keep per-caster state in `c.mem(id)`, never in fields.
## Subclass as `rite_<id>.gd`, set `id`, override what the rite needs, add ONE line to dm_rite_registry.gd. Recipe: godot/next/rites/README.md.
##
## The caster does the shared work (owner / finite aim / DmAbilities.cast_check: dead, locked, busy, cooldown, essence / cost / events / state);
## the module does only what is particular to its rite.
##
## Ported to the combat core (client/code.list "Ported"): enemies are ids (`DmFoe` snapshots), blows and statuses go through the caster (`c.deal`, `c.apply_status`),
## and the geometry helpers below answer from the core's radius query with today's rules.

var id: String = ""
var steps: bool = false   ## true: `step` runs every host tick while the caster holds `mem(id)` state


## HOST. After the shared checks, before anything is spent. Return "" to go ahead or a refusal reason ("range", "no_target", "no_corpse", ...);
## a refusal costs nothing. May stash what it found in `intent` (e.g. the picked enemy / corpse id) for `resolve`. `intent` = {rite, aim, target_id, sender}.
## Set `intent["colossus_cast"] = true` when the cast earns the Colossus cooldown (DmAbilities.apply_cast_cost).
func validate(_c: DmRiteCaster, _intent: Dictionary) -> String:
	return ""


## HOST. The cost is paid and the cooldown runs. Do the rite: roll with DmAbilities, `c.after(ms, fn)` for flight time, damage through
## `c.deal`, take corpses only through `c.corpses().consume`, then `c.broadcast({t, rite, ...})`. Return "" when it happened, or a reason
## when it could not (the caster hands the cost and cooldown back and reports the reason to the owner).
func resolve(_c: DmRiteCaster, _intent: Dictionary) -> String:
	return ""


## EVERY PEER, exactly once per broadcast event (the host included, also solo): fx via `c.fx` (DmRiteFx), floating numbers via `c.hit_number`.
## Must not touch host state: a client only has the event dictionary.
func play(_c: DmRiteCaster, _ev: Dictionary) -> void:
	pass


## HOST, every physics tick while `steps` and the caster has `mem(id)` state (zones, armed seeds, tethers).
func step(_c: DmRiteCaster, _dt: float) -> void:
	pass


# ---- shared geometry for the targeted / line rites (host) ------------------------------------------------------------------------------------
# Enemies are the core's (an id, or a DmFoe snapshot of it): the queries go through the core with today's rules (measured to the enemy's edge, spawn order,
# strict comparisons, the caps).

## The live enemy a rite is aimed at: the named one, else the nearest to the aim point within `radius` (input tolerance, not a game number).
static func pick_enemy(c: DmRiteCaster, aim: Vector3, target_id: int, radius: float = 1.5) -> DmFoe:
	if c.world == null:
		return null
	if target_id >= 0:
		var e := c.foe(target_id)
		if e != null:
			return e
	var best: DmFoe = null
	var best_d := INF
	for e2 in c.foes_in_radius(aim, radius):
		var d := Vector2(e2.x - aim.x, e2.z - aim.z).length()
		if d < best_d:
			best_d = d
			best = e2
	return best


## Live enemies in a lane from (ox, oz) along the unit direction (dx, dz): 0 < along < length (+ the enemy's radius when `pad`) and |across| < half_w + radius.
## Returns [{e: DmFoe, along}] sorted by along.
static func lane(c: DmRiteCaster, ox: float, oz: float, dx: float, dz: float, length: float, half_w: float, pad: bool) -> Array:
	var out: Array = []
	for e in c.foes_in_radius(Vector3(ox, 0.0, oz), length + 3.0):
		var r := e.radius
		var rx := e.x - ox
		var rz := e.z - oz
		var along := rx * dx + rz * dz
		if along > 0.0 and along < length + (r if pad else 0.0) and absf(rx * dz - rz * dx) < half_w + r:
			out.append({"e": e, "along": along})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["along"] < b["along"])
	return out


## EVERY PEER: a visual shot's target callable. Follows the enemy `eid` (at height `y`) while it stays in the core's table, else stays on its last point (starts at `last`).
## The point is the simulation's, where the drawn body is interpolated between ticks.
static func follow_enemy(c: DmRiteCaster, eid: int, last: Vector3, y: float) -> Callable:
	var pt := [last, -1]   # the point, and the physics frame it was read in: the core is asked once a tick, not once a rendered frame
	# A WeakRef, not the world: a shot can outlive it (teardown, area change), and a lambda that captures a freed Object logs an engine error on every call.
	var w: WeakRef = weakref(c.world) if c.world is Object else null
	return func() -> Variant:
		var frame := Engine.get_physics_frames()
		if int(pt[1]) != frame:
			pt[1] = frame
			var wo: Object = w.get_ref() if w != null else null
			var h: DmCoreHost = wo.get("core_host") as DmCoreHost if wo != null else null
			if h != null and h.core != null:
				var p := h.enemy_position(eid)
				if p != Vector3.INF:
					pt[0] = Vector3(p.x, y, p.z)
		return pt[0]


## HOST helper (the sim's _in_circle): the living, hittable enemies whose edge is within `r` of (x, z), at most `cap` (nearest-first is not promised).
static func enemies_in_circle(c: DmRiteCaster, x: float, z: float, r: float, cap: int = 64) -> Array[DmFoe]:
	var out: Array[DmFoe] = []
	for e in c.foes_in_radius(Vector3(x, 0.0, z), r + 1.5):
		if not e.hittable():
			continue
		if Vector2(e.x - x, e.z - z).length() > r + e.radius:
			continue
		out.append(e)
		if out.size() >= cap:
			break
	return out


## HOST helper (the sim's _face): turn the caster's body toward the ground point (x, z).
static func face(c: DmRiteCaster, x: float, z: float) -> void:
	var b: Node3D = c.body
	if b != null and b.get("yaw") != null:
		var d := Vector2(x - b.position.x, z - b.position.z)
		if d.length_squared() > 0.0001:
			b.set("yaw", atan2(d.x, d.y))
			b.rotation.y = float(b.get("yaw"))


## The ground point `aim` pulled back along the line from the caster to at most `reach` metres (the sim's clampAim; the aim stays when inside).
static func clamp_reach(from: Vector3, aim: Vector3, reach: float) -> Vector3:
	var d := Vector2(aim.x - from.x, aim.z - from.z).length()
	if d <= reach or d < 1e-6:
		return Vector3(aim.x, 0.0, aim.z)
	return Vector3(from.x + (aim.x - from.x) / d * reach, 0.0, from.z + (aim.z - from.z) / d * reach)
