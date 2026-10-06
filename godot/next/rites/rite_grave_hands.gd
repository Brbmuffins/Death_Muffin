extends DmRiteModule
## Grave Hands: the buried dead claw up through a 3.5 m field at the cursor (clamped to 10 m) for 3 s. Every 0.5 s (first rake 60 ms in) each enemy
## inside takes spell power x 0.4 x (1 + 15% per corpse in the field at cast time, up to 4) and is Slowed (the MIASMA_SLOW rule, held tickS + 0.2 s,
## DmStatusSet `slow`). The corpses stay. 26 essence, 11 s, level 11. Numbers: DmAbilities.grave_hands (corpses, hands, dmg) + DmSimData.GRAVE_HANDS.
## Host zone state lives in `c.mem(id)["zones"]` (a tiny array, a rake every 0.5 s, nothing allocated between rakes); every peer keeps the fx handles
## in `c.mem(id)["fx"]` and drops them on the `end` event. Visuals: DmRiteFx.hands_start / hands_tick / hands_end.

const MAX_HITS := 64
const POPUPS := 4
const FIRST_TICK_MS := 60.0


func _init() -> void:
	id = "grave_hands"
	steps = true


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var G: Dictionary = DmSimData.GRAVE_HANDS
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
	var field := c.corpses()
	var found: int = field.corpses_in_radius(Vector3(x, 0.0, z), r, Callable(), "", false).size() if field != null else 0
	var h := DmAbilities.grave_hands(DmAbilities.sp(c.p, c.now_ms), float(found))
	var m := c.mem(id)
	var zid := int(m.get("n", 0)) + 1
	m["n"] = zid
	var zones: Array = m.get_or_add("zones", [])
	zones.append({"id": zid, "x": x, "z": z, "r": r, "dmg": float(h["dmg"]), "until": c.now_ms + float(G["durationS"]) * 1000.0, "next": c.now_ms + FIRST_TICK_MS})
	c.broadcast({"t": "field", "rite": id, "by": c.peer_id, "zid": zid, "x": x, "z": z, "r": r, "hands": int(h["hands"]), "dur": float(G["durationS"])})
	return ""


func step(c: DmRiteCaster, _dt: float) -> void:
	var zones: Array = c.mem(id).get("zones", [])
	var i := zones.size() - 1
	while i >= 0:
		var z: Dictionary = zones[i]
		var done: bool = c.now_ms >= float(z["until"]) or not bool(c.p["alive"])
		while not done and c.now_ms >= float(z["next"]):
			z["next"] = float(z["next"]) + float(DmSimData.GRAVE_HANDS["tickS"]) * 1000.0
			_rake(c, z)
		if done:
			c.broadcast({"t": "end", "rite": id, "by": c.peer_id, "zid": int(z["id"])})
			zones.remove_at(i)
		i -= 1


func _rake(c: DmRiteCaster, z: Dictionary) -> void:
	var hold := float(DmSimData.GRAVE_HANDS["tickS"]) + 0.2
	var pts: Array = []
	var n := 0
	for e: DmEnemy in DmRiteModule.enemies_in_circle(c, float(z["x"]), float(z["z"]), float(z["r"]), MAX_HITS):
		DmStatusSet.hit(e, float(z["dmg"]), c.body)
		var dead := float(e.get("hp")) <= 0.0
		if not dead:
			DmStatusSet.ensure(e).apply(&"slow", c.body, 1, hold)
		c.hit_resolved.emit(id, int(c.world.enemy_id(e)), float(z["dmg"]), false, dead)
		if pts.size() < POPUPS:
			pts.append([e.global_position.x, e.global_position.z])
		n += 1
	c.broadcast({"t": "rake", "rite": id, "by": c.peer_id, "x": float(z["x"]), "z": float(z["z"]), "r": float(z["r"]), "pts": pts, "n": n, "dmg": float(z["dmg"])})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var fxs: Dictionary = c.mem(id).get_or_add("fx", {})
	match String(ev["t"]):
		"field":
			fxs[int(ev["zid"])] = c.fx.hands_start(float(ev["x"]), float(ev["z"]), float(ev["r"]), int(ev["hands"]), float(ev["dur"]))
		"rake":
			c.fx.hands_tick(float(ev["x"]), float(ev["z"]), float(ev["r"]), ev["pts"])
			if c.is_owner_peer():
				for h: Array in ev["pts"]:
					c.hit_number.emit(Vector3(h[0], 0.8, h[1]), float(ev["dmg"]), false)
		"end":
			var vis: Variant = fxs.get(int(ev["zid"]))
			if vis != null:
				c.fx.hands_end(vis)
				fxs.erase(int(ev["zid"]))
