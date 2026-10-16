extends DmRiteModule
## Ossuary Wall (the Ossuary's signature, R): a 7 m x 0.8 m wall of fused bone across the cursor line for 6 s, centred on the aim (pulled back to 10 m), standing
## perpendicular to the line from you to it. 30 essence, 16 s, unlocks at level 10. Numbers: DmSimData.SIGNATURE.wall + the def (sim_signatures "wall").
## On the combat core (client/code.list "Ported"): the wall is NOT solid for the core's enemies yet. Today it is a StaticBody3D on the physics layer enemies collide with plus a
## NavigationObstacle3D; the core's enemies have no physics body and steer by their own movement, which has no dynamic obstacle (native/README.md "Differences from today's game"),
## so only the ribs (DmRiteFx.wall_raise, a sibling node on every peer) and the 6 s lifetime are ported. Events: `raise`, `gone`.


func _init() -> void:
	id = "ossuary_wall"
	steps = true


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var W: Dictionary = DmSimData.SIGNATURE["wall"]
	var from := c.pos()
	var at := clamp_reach(from, intent["aim"], float(DmAbilities.def(id)["range"]))
	var dir := Vector2(at.x - from.x, at.z - from.z)
	dir = Vector2(0.0, -1.0) if dir.length() < 1e-6 else dir.normalized()
	var half := Vector2(-dir.y, dir.x) * (float(W["length"]) / 2.0)
	var m := c.mem(id)
	var walls: Array = m.get_or_add("walls", [])
	m["n"] = int(m.get("n", 0)) + 1
	var wid := int(m["n"])
	var ms := float(W["durationS"]) * 1000.0
	walls.append({"id": wid, "until": c.now_ms + ms, "x": at.x, "z": at.z})
	c.broadcast({"t": "raise", "rite": id, "by": c.peer_id, "id": wid, "tip": c.tip(), "x0": at.x - half.x, "z0": at.z - half.y, "x1": at.x + half.x, "z1": at.z + half.y, "ms": ms})
	return ""


## Host: the wall ends when its time is up.
func step(c: DmRiteCaster, _dt: float) -> void:
	var walls: Array = c.mem(id).get("walls", [])
	var i := 0
	while i < walls.size():
		var w: Dictionary = walls[i]
		if c.now_ms < float(w["until"]):
			i += 1
			continue
		walls.remove_at(i)
		c.broadcast({"t": "gone", "rite": id, "by": c.peer_id, "id": int(w["id"]), "x": float(w["x"]), "z": float(w["z"])})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var wid := int(ev["id"])
	if String(ev["t"]) == "gone":
		var ribs := c.get_node_or_null("Ribs%d" % wid) as Node3D
		if ribs != null:
			c.fx.wall_gone(float(ev["x"]), float(ev["z"]))
			ribs.queue_free()
		return
	c.fx.signature_cast("wall", ev["tip"])
	c.add_child(c.fx.wall_raise(float(ev["x0"]), float(ev["z0"]), float(ev["x1"]), float(ev["z1"]), "Ribs%d" % wid))
	c.shake_requested.emit(0.15)
