class_name DmPfUtil
extends RefCounted
## Shared helpers of the Cinder Pyre / Mourning Fen kinds (fire pools, chill / pull / curse on targets, look, line-of-sight). Static, no state.

const FALLBACK_LOOK := {"cinder_husk": "grave_robber", "pyre_priest": "deacon", "cinderhound": "bone_hound", "slag_brute": "bone_golem",
	"bog_hag": "deacon", "mire_leech": "skull_rat", "fen_wisp": "choir_wraith", "drowned_sexton": "bone_golem"}
const WISP_GLOW := 0x7fe0d0   ## views: the Fen Wisp is an emissive marsh-light


## DmEnemy.look_options() plus this kind's missing-model fallback rig and the wisp glow.
static func look(o: Dictionary, def_id: String) -> Dictionary:
	if FALLBACK_LOOK.has(def_id):
		o["fallback"] = FALLBACK_LOOK[def_id]
	if def_id == "fen_wisp" and not o.has("emissive"):
		o["emissive"] = WISP_GLOW
		o["emissive_intensity"] = 0.9
	return o


## What this enemy's blow is worth right now (Bone Hex softens it), the sim's `blow(e)`.
static func blow(e: DmEnemy) -> float:
	var st := DmStatusSet.of(e)
	return e.damage * (st.damage_dealt_mult() if st != null else 1.0)


static func is_thrall(tg: Node) -> bool:
	return &"cursed_t" in tg


## A burning pool (kind `ember`): damaging on the authority, visual-only on every other peer (REBUILD: zones are host-spawned).
static func ember_pool(e: DmEnemy, at: Vector3, r: float, seconds: float, dps: float) -> DmHostileZone:
	var z := DmHostileZone.spawn(e.get_parent(), at, &"ember", r, seconds, dps, e)
	z.damaging = e.is_multiplayer_authority()
	return z


## Chill a target (Fen Wisp pulse / Bog Hag hex). A target that handles the effect itself (`dm_enemy_effect`) gets it; otherwise its DmStatusSet.
static func chill(e: DmEnemy, tg: Node, seconds: float) -> void:
	if tg.has_method("dm_enemy_effect"):
		tg.dm_enemy_effect(&"chill", {"seconds": seconds, "from": e})
		return
	var st := DmStatusSet.of(tg)
	if st != null:
		st.apply(&"chill", e, 1, seconds)


## Drag a target `m` metres toward `to` (never closer than 1.6 m) and root it `root_s` seconds (Drowned Sexton's hook).
static func pull(e: DmEnemy, tg: Node3D, to: Vector3, m: float, root_s: float) -> void:
	var p := tg.global_position
	var d := Vector2(to.x - p.x, to.z - p.z)
	var len := d.length()
	var step := minf(m, maxf(0.0, len - 1.6))
	if step > 0.05:
		var dest := Vector3(p.x + d.x / len * step, p.y, p.z + d.y / len * step)
		if tg.has_method("dm_enemy_effect"):
			tg.dm_enemy_effect(&"pull", {"to": dest, "from": e})
		elif tg.has_method("teleport"):
			tg.teleport(dest)
		else:
			tg.global_position = dest
			tg.reset_physics_interpolation()
	if tg.has_method("dm_enemy_effect"):
		tg.dm_enemy_effect(&"root", {"seconds": root_s, "from": e})
	else:
		var st := DmStatusSet.of(tg)
		if st != null:
			st.apply(&"root", e, 1, root_s)


## True when the world layer (walls, pillars, crates) blocks the straight line a -> b at chest height.
static func wall_between(e: Node3D, a: Vector3, b: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(Vector3(a.x, 1.0, a.z), Vector3(b.x, 1.0, b.z), DmEnemy.LAYER_WORLD)
	return not e.get_world_3d().direct_space_state.intersect_ray(q).is_empty()
