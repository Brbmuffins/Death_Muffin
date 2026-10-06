extends DmRiteModule
## Ossuary Wall (the Ossuary's signature, R): a 7 m x 0.8 m wall of fused bone across the cursor line for 6 s, centred on the aim (pulled back to 10 m), standing
## perpendicular to the line from you to it. 30 essence, 16 s, unlocks at level 10. Numbers: DmSimData.SIGNATURE.wall + the def (sim_signatures "wall").
## The dead cannot pass it: on the host the wall is a StaticBody3D on the physics layer enemies collide with (DmEnemy.LAYER_PLAYER: enemies mask world + player,
## thralls mask world only, so your legion walks through) and a NavigationObstacle3D (avoidance, so a crowd steers round it); both are removed when it expires.
## The ribs (DmRiteFx.wall_raise) are a sibling node on every peer. Both are children of the caster (a plain Node, so their transforms are the world's).
## Events: `raise`, `gone`.

const HEIGHT := 2.4


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
	_physics(c, wid, at, half, float(W["thickness"]))
	walls.append({"id": wid, "until": c.now_ms + ms, "x": at.x, "z": at.z})
	c.broadcast({"t": "raise", "rite": id, "by": c.peer_id, "id": wid, "tip": c.tip(), "x0": at.x - half.x, "z0": at.z - half.y, "x1": at.x + half.x, "z1": at.z + half.y, "ms": ms})
	return ""


func _physics(c: DmRiteCaster, wid: int, at: Vector3, half: Vector2, thickness: float) -> void:
	var node := Node3D.new()
	node.name = "Wall%d" % wid
	c.add_child(node)
	node.position = at
	node.rotation.y = atan2(-half.y, half.x)   # local +X runs along the wall
	var length := half.length() * 2.0
	var body := StaticBody3D.new()
	body.name = "Block"
	body.collision_layer = DmEnemy.LAYER_PLAYER
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(length, HEIGHT, thickness)
	cs.shape = box
	cs.position.y = HEIGHT * 0.5
	body.add_child(cs)
	node.add_child(body)
	var ob := NavigationObstacle3D.new()
	ob.name = "Nav"
	ob.height = HEIGHT
	ob.vertices = PackedVector3Array([Vector3(-length / 2.0, 0.0, -thickness / 2.0), Vector3(-length / 2.0, 0.0, thickness / 2.0), Vector3(length / 2.0, 0.0, thickness / 2.0), Vector3(length / 2.0, 0.0, -thickness / 2.0)])
	ob.affect_navigation_mesh = false   # a runtime rebake would cost far more than a 6 s wall is worth; the collider blocks, the obstacle steers
	ob.avoidance_enabled = true
	node.add_child(ob)


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
		var n := c.get_node_or_null("Wall%d" % wid)   # host: collider + obstacle
		if n != null:
			n.queue_free()
		return
	c.fx.signature_cast("wall", ev["tip"])
	c.add_child(c.fx.wall_raise(float(ev["x0"]), float(ev["z0"]), float(ev["x1"]), float(ev["z1"]), "Ribs%d" % wid))
	c.shake_requested.emit(0.15)
