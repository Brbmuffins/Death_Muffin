extends DmRiteModule
## Command: Rend (the Gravecaller's signature, R): your whole legion leaps to the cursor (pulled back to 13 m, and to where your area ends) and cleaves everything around
## it, each thrall paying 15 % of its health instead of essence (DmThrallHost.command_rend: ring of 1.2 m, cleave 2.2 m, damage x 2.5; numbers DmSimData.SIGNATURE.rend).
## Free, 9 s, unlocks at level 10, refused `no_thralls` without a living legion. Visuals: DmRiteFx.rend (a jade beam and claw per thrall).

const STEP := 0.5   ## sim_signatures.last_point_in_area walks the line in 0.5 m steps


func _init() -> void:
	id = "command_rend"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var host := c.thralls()
	if host == null:
		return "no_thralls"
	var living := false
	for t in host.list():
		if t.state != DmThrall.S.RISING and t.state != DmThrall.S.DEAD:
			living = true
			break
	if not living:
		return "no_thralls"
	var from := c.pos()
	var at := clamp_reach(from, intent["aim"], float(DmAbilities.def(id)["range"]))
	var area := c.area()
	if area != "" and c.world.has_method("area_at"):   # stop at the last point still inside the caster's area
		var n := maxi(1, int(ceilf(Vector2(at.x - from.x, at.z - from.z).length() / STEP)))
		var best := from
		for i in range(1, n + 1):
			var p := from.lerp(at, float(i) / float(n))
			if String(c.world.area_at(p.x, p.z)) != area:
				break
			best = p
		at = Vector3(best.x, 0.0, best.z)
	intent["point"] = at
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var at: Vector3 = intent["point"]
	var leaps: Array = []
	var hits := c.thralls().command_rend(at, leaps)
	c.broadcast({"t": "rend", "rite": id, "by": c.peer_id, "tip": c.tip(), "x": at.x, "z": at.z, "leaps": leaps, "hits": hits})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	c.fx.signature_cast("rend", ev["tip"])
	var shake := c.fx.rend(ev["leaps"], float(ev["x"]), float(ev["z"]), c.is_owner_peer())
	if shake > 0.0:
		c.shake_requested.emit(shake)
