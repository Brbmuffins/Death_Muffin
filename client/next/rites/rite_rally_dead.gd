extends DmRiteModule
## Rally the Dead: every thrall you command (DmThrallHost.rally) is healed 20%, hits 40% harder and swings 30% faster for 6 s (Gravecaller +2 s) and
## turns on the enemy nearest the cursor (within the leash). 20 essence, 12 s, level 6; refused `no_thralls` with an empty legion (free). The host
## applies it once; ONE event goes to every peer, which plays the beams / sigils / rims / sound exactly once (the original game's double-dispatch bug
## drew them twice). Numbers: DmSimData.RALLY (the core applies them). Visuals: DmRiteFx.rally_cast / rally; the follow targets read the thralls' positions.
## On the combat core: the legion is the core's (`c.thralls()`: rally heals, hastens and retargets inside the core), a thrall is an id.

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
	var focus: DmFoe = null
	var best := INF
	for e in c.foes_in_radius(Vector3(x, 0.0, z), FOCUS_SEARCH):
		if not e.hittable():
			continue
		var dd := Vector2(e.x - x, e.z - z).length()
		if dd < best:
			best = dd
			focus = e
	host.rally(secs, focus.id if focus != null else 0)
	var ids: Array = Array(host.active())
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
		var t: Dictionary = host.info(tid) if host != null else {}
		if t.is_empty() or int(t["state"]) == DmCoreEvents.ThrallState.DEAD:
			return null
		var tp: Vector2 = t["pos"]
		return Vector3(tp.x, 0.0, tp.y)
	c.fx.rally_cast(float(ev["px"]), float(ev["pz"]))
	c.fx.rally(ev, follow, thrall_at)
