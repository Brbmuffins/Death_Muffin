extends DmRiteModule
## Bone Storm (grimoire, level 14): a funnel of bone dropped at the cursor (ground, clamped to 10 m, 32 essence, 12 s, power 0.5). It lasts 4 s + 0.6 s per
## corpse under it (up to +3 s; the corpses are only counted, not consumed), drifts 2.2 m/s toward the nearest enemy within 9 m and every 0.4 s hits everything
## within r 2 (+ the enemy's radius). Numbers: DmAbilities.bone_storm_life_s + BONE_STORM. Host: `mem("bone_storm").storms`; every peer draws it following the
## host's tick events (the funnel drifts toward the last reported centre at the same 2.2 m/s, so it is smooth between ticks).

const MAX_TARGETS := 64


func _init() -> void:
	id = "bone_storm"
	steps = true


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var B: Dictionary = DmCombatData.const_table("BONE_STORM")
	var def := DmAbilities.def(id)
	var aim: Vector3 = intent["aim"]
	var origin := c.pos()
	var d := Vector2(aim.x - origin.x, aim.z - origin.z).length()
	var x := aim.x
	var z := aim.z
	if d > float(def["range"]):
		x = origin.x + (aim.x - origin.x) / d * float(def["range"])
		z = origin.z + (aim.z - origin.z) / d * float(def["range"])
	var r := float(def["radius"])
	var field := c.corpses()
	var found := float(field.corpses_in_radius(Vector3(x, 0.0, z), r, Callable(), c.area()).size()) if field != null else 0.0
	var life := DmAbilities.bone_storm_life_s(found)
	var m := c.mem(id)
	var storms: Array = m.get_or_add("storms", [])
	var sid := int(m.get("sid", 0)) + 1
	m["sid"] = sid
	storms.append({"sid": sid, "x": x, "z": z, "r": r, "dmg": DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id), "until": c.now_ms + life * 1000.0,
		"next": c.now_ms + float(B["tickS"]) * 1000.0, "last": c.now_ms})
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "sid": sid, "x": x, "z": z, "r": r, "life": life})
	return ""


func step(c: DmRiteCaster, _dt: float) -> void:
	var storms: Array = c.mem(id).get("storms", [])
	var i := storms.size() - 1
	while i >= 0:
		var s: Dictionary = storms[i]
		if not bool(c.p["alive"]) or c.now_ms >= float(s["until"]):
			storms.remove_at(i)
		elif c.now_ms >= float(s["next"]):
			_tick(c, s)
		i -= 1


func _tick(c: DmRiteCaster, s: Dictionary) -> void:
	var B: Dictionary = DmCombatData.const_table("BONE_STORM")
	s["next"] = float(s["next"]) + float(B["tickS"]) * 1000.0
	var dt := minf(1.0, (c.now_ms - float(s["last"])) / 1000.0)
	s["last"] = c.now_ms
	var cx := float(s["x"])
	var cz := float(s["z"])
	var best: Node3D = null
	var best_d := float(B["seekR"])
	for n in c.world.enemies_in_radius(Vector3(cx, 0.0, cz), best_d):
		var e := n as Node3D
		if e == null or not DmRiteCaster.alive_enemy(e):
			continue
		var d := Vector2(e.global_position.x - cx, e.global_position.z - cz).length()
		if d < best_d:
			best_d = d
			best = e
	if best != null and best_d > 0.3:
		var step := minf(best_d, float(B["drift"]) * dt)
		cx += (best.global_position.x - cx) / best_d * step
		cz += (best.global_position.z - cz) / best_d * step
		s["x"] = cx
		s["z"] = cz
	var hit := 0
	var r := float(s["r"])
	for n in c.world.enemies_in_radius(Vector3(cx, 0.0, cz), r + 3.0):
		var e := n as Node3D
		if e == null or not DmRiteCaster.alive_enemy(e):
			continue
		if Vector2(e.global_position.x - cx, e.global_position.z - cz).length() > r + float(e.get("radius")):
			continue
		if DmStatusSet.hit(e, float(s["dmg"]), c.body):
			hit += 1
			c.hit_resolved.emit(id, int(c.world.enemy_id(e)), float(s["dmg"]), false, float(e.get("hp")) <= 0.0)
		if hit >= MAX_TARGETS:
			break
	c.broadcast({"t": "tick", "rite": id, "by": c.peer_id, "sid": int(s["sid"]), "x": cx, "z": cz, "r": r, "hit": hit > 0})
	if hit > 0:
		c.push_state()


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var vis: Dictionary = c.mem(id).get_or_add("vis", {})   # per peer: the storms this peer is drawing
	var sid := int(ev["sid"])
	match String(ev["t"]):
		"cast":
			var now := Time.get_ticks_msec()
			for k in vis.keys():
				if now >= int(vis[k]["until"]):
					vis.erase(k)
			var v := {"pos": Vector2(float(ev["x"]), float(ev["z"])), "target": Vector2(float(ev["x"]), float(ev["z"])), "last": now, "until": now + int(float(ev["life"]) * 1000.0)}
			vis[sid] = v
			c.fx.storm_start(float(ev["life"]), float(ev["r"]), func() -> Variant: return _follow(v), float(ev["x"]), float(ev["z"]))
		"tick":
			if vis.has(sid):
				vis[sid]["target"] = Vector2(float(ev["x"]), float(ev["z"]))
			c.fx.storm_tick(float(ev["x"]), float(ev["z"]), float(ev["r"]), bool(ev["hit"]))


## The funnel's ground point: drifts toward the host's last centre at the storm's own speed; null once it is over.
func _follow(v: Dictionary) -> Variant:
	var now := Time.get_ticks_msec()
	if now >= int(v["until"]):
		return null
	if now != int(v["last"]):
		var p: Vector2 = v["pos"]
		v["pos"] = p.move_toward(v["target"], float(DmCombatData.const_table("BONE_STORM")["drift"]) * float(now - int(v["last"])) / 1000.0)
		v["last"] = now
	var q: Vector2 = v["pos"]
	return Vector3(q.x, 0.0, q.y)
