extends DmRiteModule
## Bone Mantle: draw up to 5 corpses within 6 m (nearest first, only through the field's atomic consume) into a mantle: a barrier of 10% max health +7% per
## corpse (never lowering the current one, held 6 s) while bone shards shred the enemies beside you every tickS. 25 essence, 15 s, unlocks at level 12.
## Numbers: DmAbilities.mantle_apply / mantle_shard_damage + DmSimData.BONE_MANTLE; the barrier goes on the body's DmPlayerRules vitals (the same
## state damage soaks through). Visuals: DmRiteFx.mantle (tethers, orbiting shards, ring).

const MAX_HITS := 64


func _init() -> void:
	id = "bone_mantle"
	steps = true


func resolve(c: DmRiteCaster, _intent: Dictionary) -> String:
	var M: Dictionary = DmSimData.BONE_MANTLE
	var field := c.corpses()
	var at := c.pos()
	var n := 0
	var tethers: Array = []
	if field != null:
		for cp: DmSimCorpse in field.corpses_in_radius(at, float(DmAbilities.def(id)["radius"]), Callable(), c.area()).slice(0, int(M["maxCorpses"])):
			var cx := cp.x
			var cz := cp.z
			if field.consume(cp.id, c.peer_id, "consumed"):
				n += 1
				tethers.append([cx, cz])
	c.set_mantle_barrier(n)
	var m := c.mem(id)
	m["until"] = c.now_ms + float(M["durationS"]) * 1000.0
	m["next"] = c.now_ms + float(M["tickS"]) * 1000.0
	c.broadcast({"t": "mantle", "rite": id, "by": c.peer_id, "x": at.x, "z": at.z, "corpses": n, "tethers": tethers})
	return ""


## The shards: every tickS inside the mantle each enemy within orbitRadius + 0.4 (+ its edge) takes the shard damage.
func step(c: DmRiteCaster, _dt: float) -> void:
	var m := c.mem(id)
	if not m.has("until"):
		return
	if c.now_ms >= float(m["until"]) or not bool(c.p["alive"]):
		m.clear()
		return
	if c.now_ms < float(m["next"]):
		return
	var M: Dictionary = DmSimData.BONE_MANTLE
	m["next"] = c.now_ms + float(M["tickS"]) * 1000.0
	var dmg := DmAbilities.mantle_shard_damage(DmAbilities.sp(c.p, c.now_ms))
	var hit: Array = []
	var n := 0
	for e_n in c.world.enemies_in_radius(c.pos(), float(M["orbitRadius"]) + 0.4):
		var e := e_n as Node3D
		if e == null or not DmRiteCaster.alive_enemy(e):
			continue
		DmStatusSet.hit(e, dmg, c.body)
		c.hit_resolved.emit(id, int(c.world.enemy_id(e)), dmg, false, float(e.get("hp")) <= 0.0)
		if hit.size() < 6:
			hit.append([e.global_position.x, e.global_position.z])
		n += 1
		if n >= MAX_HITS:
			break
	if n > 0:
		c.broadcast({"t": "shard", "rite": id, "by": c.peer_id, "hits": hit, "dmg": dmg})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var mine := c.is_owner_peer()
	match String(ev["t"]):
		"mantle":
			var bw: WeakRef = weakref(c.body)   # a WeakRef, not the body: a lambda capturing a freed Object logs an engine error on every call
			var follow := func() -> Variant:
				var b: Node3D = bw.get_ref() as Node3D
				return Vector3(b.global_position.x, 0.0, b.global_position.z) if b != null else null
			var hs := c.fx.mantle(ev, mine, follow)
			var st := c.mem(id)
			DmRiteFx.kill(st.get("fx_orbit"))
			DmRiteFx.kill(st.get("fx_ring"))
			st["fx_orbit"] = hs[0]
			st["fx_ring"] = hs[1]
			if mine:
				c.shake_requested.emit(0.04)
		"shard":
			var MN := DmFxData.spell_group("mantle")
			for h: Array in ev["hits"]:
				c.fx.emit(h[0], 0.9, h[1], 4, MN["bone"], 0.2, 2.2, 1.0, 0.3, 0.12, {"gravity": 8.0})
				if mine:
					c.hit_number.emit(Vector3(h[0], 0.9, h[1]), float(ev["dmg"]), false)
			var bp: Vector3 = c.body.global_position
			c.fx.sfx("boneHit", bp.x, bp.z)
