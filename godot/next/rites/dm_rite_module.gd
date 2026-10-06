class_name DmRiteModule
extends RefCounted
## One rite of the DmRiteCaster. A module is a shared, stateless singleton (see DmRiteRegistry): keep per-caster state in `c.mem(id)`, never in fields.
## Subclass as `rite_<id>.gd`, set `id`, override what the rite needs, add ONE line to dm_rite_registry.gd. Recipe: godot/next/rites/README.md.
##
## The caster does the shared work (owner / finite aim / DmAbilities.cast_check: dead, locked, busy, cooldown, essence / cost / events / state);
## the module does only what is particular to its rite.

var id: String = ""
var steps: bool = false   ## true: `step` runs every host tick while the caster holds `mem(id)` state


## HOST. After the shared checks, before anything is spent. Return "" to go ahead or a refusal reason ("range", "no_target", "no_corpse", ...);
## a refusal costs nothing. May stash what it found in `intent` (e.g. the picked enemy / corpse id) for `resolve`. `intent` = {rite, aim, target_id, sender}.
## Set `intent["colossus_cast"] = true` when the cast earns the Colossus cooldown (DmAbilities.apply_cast_cost).
func validate(_c: DmRiteCaster, _intent: Dictionary) -> String:
	return ""


## HOST. The cost is paid and the cooldown runs. Do the rite: roll with DmAbilities, `c.after(ms, fn)` for flight time, damage through
## DmStatusSet.hit, take corpses only through DmCorpseField.consume, then `c.broadcast({t, rite, ...})`. Return "" when it happened, or a reason
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

## The live enemy a rite is aimed at: the named one, else the nearest to the aim point within `radius` (input tolerance, not a game number).
static func pick_enemy(c: DmRiteCaster, aim: Vector3, target_id: int, radius: float = 1.5) -> Node3D:
	if c.world == null:
		return null
	if target_id >= 0:
		var e := c.world.enemy_by_id(target_id) as Node3D
		if e != null and DmRiteCaster.alive_enemy(e):
			return e
	var best: Node3D = null
	var best_d := INF
	for n in c.world.enemies_in_radius(aim, radius):
		var e2 := n as Node3D
		if e2 == null or not DmRiteCaster.alive_enemy(e2):
			continue
		var d := Vector2(e2.global_position.x - aim.x, e2.global_position.z - aim.z).length()
		if d < best_d:
			best_d = d
			best = e2
	return best


## Live enemies in a lane from (ox, oz) along the unit direction (dx, dz): 0 < along < length (+ the enemy's radius when `pad`) and |across| < half_w + radius.
## Returns [{e, along}] sorted by along.
static func lane(c: DmRiteCaster, ox: float, oz: float, dx: float, dz: float, length: float, half_w: float, pad: bool) -> Array:
	var out: Array = []
	for n in c.world.enemies_in_radius(Vector3(ox, 0.0, oz), length + 3.0):
		var e := n as Node3D
		if e == null or not DmRiteCaster.alive_enemy(e):
			continue
		var r := float(e.get("radius"))
		var rx := e.global_position.x - ox
		var rz := e.global_position.z - oz
		var along := rx * dx + rz * dz
		if along > 0.0 and along < length + (r if pad else 0.0) and absf(rx * dz - rz * dx) < half_w + r:
			out.append({"e": e, "along": along})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["along"] < b["along"])
	return out


## EVERY PEER: a visual shot's target callable. Follows the enemy `eid` (at height `y`) while it lives, else stays on its last point (starts at `last`).
static func follow_enemy(c: DmRiteCaster, eid: int, last: Vector3, y: float) -> Callable:
	var pt := [last]
	var w := c.world   # captured by value: the shot may outlive this node
	return func() -> Variant:
		var e := w.enemy_by_id(eid) as Node3D if w != null else null
		if e != null and is_instance_valid(e):
			pt[0] = Vector3(e.global_position.x, y, e.global_position.z)
		return pt[0]
