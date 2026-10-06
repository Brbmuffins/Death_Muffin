extends DmRiteModule
## Bone Prison: a ring of bone spikes bursts at the cursor (clamped to 11 m), radius 2.4. Everything inside takes spell power x 1.1, is Rooted 1.8 s
## (move 0, it still turns and swings) and gains a Fracture stack (the hit lands first, then the stack, like the sim). 24 essence, 9 s, level 9.
## Numbers: DmAbilities.rite_damage + DmSimData.BONE_PRISON; statuses only through DmStatusSet (`root`, `fracture`). Visuals: DmRiteFx.prison.

const MAX_HITS := 64
const POPUPS := 6


func _init() -> void:
	id = "bone_prison"


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var P: Dictionary = DmSimData.BONE_PRISON
	var o := c.pos()
	var aim: Vector3 = intent["aim"]
	var x := aim.x
	var z := aim.z
	var rng := float(DmAbilities.def(id)["range"])
	var d := Vector2(x - o.x, z - o.z).length()
	if d > rng:
		x = o.x + (x - o.x) / d * rng
		z = o.z + (z - o.z) / d * rng
	DmRiteModule.face(c, x, z)
	var r := float(DmAbilities.def(id)["radius"])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var nums: Array = []
	var n := 0
	for e: DmEnemy in DmRiteModule.enemies_in_circle(c, x, z, r, MAX_HITS):
		DmStatusSet.hit(e, dmg, c.body)
		var dead := float(e.get("hp")) <= 0.0
		if not dead:
			var ss := DmStatusSet.ensure(e)
			ss.apply(&"root", c.body, 1, float(P["rootS"]))
			ss.apply(&"fracture", c.body, int(P["fracture"]))
		c.hit_resolved.emit(id, int(c.world.enemy_id(e)), dmg, false, dead)
		if nums.size() < POPUPS:
			nums.append([e.global_position.x, e.global_position.z])
		n += 1
	c.broadcast({"t": "burst", "rite": id, "by": c.peer_id, "x": x, "z": z, "r": r, "nums": nums, "n": n, "dmg": dmg})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var mine := c.is_owner_peer()
	c.fx.prison(float(ev["x"]), float(ev["z"]), float(ev["r"]))
	if mine:
		for h: Array in ev["nums"]:
			c.hit_number.emit(Vector3(h[0], 1.0, h[1]), float(ev["dmg"]), false)
		c.shake_requested.emit(0.06)
