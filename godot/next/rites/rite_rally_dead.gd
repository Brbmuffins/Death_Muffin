extends DmRiteModule
## Rally the Dead: every thrall you command (DmThrallHost.rally) is healed 20%, hits 40% harder and swings 30% faster for 6 s (Gravecaller +2 s) and
## turns on the enemy nearest the cursor (within the leash). 20 essence, 12 s, level 6; refused `no_thralls` with an empty legion (free). The host
## applies it once; ONE event goes to every peer, which plays the beams / sigils / rims / sound exactly once (the original game's double-dispatch bug
## drew them twice). Numbers: DmSimData.RALLY + DmThrall.rally. Visuals: DmRiteFx.rally_cast / rally; the follow targets read the thrall puppets.

const FOCUS_SEARCH := 30.0


func _init() -> void:
	id = "rally_dead"


func validate(c: DmRiteCaster, _intent: Dictionary) -> String:
	var host := c.thralls()
	return "" if host != null and host.count() > 0 else "no_thralls"


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var RL: Dictionary = DmSimData.RALLY
	var host := c.thralls()
	var o := c.pos()
	var aim: Vector3 = intent["aim"]
	var x := aim.x
	var z := aim.z
	var rng := float(DmAbilities.def(id)["range"])
	var d := Vector2(x - o.x, z - o.z).length()
	if d > rng:
		x = o.x + (x - o.x) / d * rng
		z = o.z + (z - o.z) / d * rng
	var secs := float(RL["durationS"]) + (float(RL["gravecallerBonusS"]) if String(c.body.get("discipline_id")) == "gravecaller" else 0.0)
	var focus: DmEnemy = null
	var best := INF
	for n in c.world.enemies_in_radius(Vector3(x, 0.0, z), FOCUS_SEARCH):
		var e := n as DmEnemy
		if e == null or not DmRiteCaster.alive_enemy(e) or not e.is_hittable():
			continue
		var dd := Vector2(e.global_position.x - x, e.global_position.z - z).length()
		if dd < best:
			best = dd
			focus = e
	host.rally(secs, focus)
	var ids: Array = []
	for t in host.list():
		if t.state != DmThrall.S.RISING and t.state != DmThrall.S.DEAD:
			ids.append(t.id)
	c.broadcast({"t": "rally", "rite": id, "by": c.peer_id, "x": x, "z": z, "px": o.x, "pz": o.z, "ids": ids, "dur": minf(secs, float(RL["durationS"]) + float(RL["gravecallerBonusS"]))})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var b: Node3D = c.body
	var follow := func() -> Variant:
		return Vector3(b.global_position.x, 0.0, b.global_position.z) if is_instance_valid(b) else null
	var until := Time.get_ticks_msec() + int(float(ev["dur"]) * 1000.0)
	var thrall_at := func(tid: int) -> Variant:
		if Time.get_ticks_msec() > until or not is_instance_valid(b):
			return null
		var host := c.thralls()
		var t: DmThrall = host.by_id(tid) if host != null else null
		if t == null or t.state == DmThrall.S.DEAD:
			return null
		return Vector3(t.global_position.x, 0.0, t.global_position.z)
	c.fx.rally_cast(float(ev["px"]), float(ev["pz"]))
	c.fx.rally(ev, follow, thrall_at)
