class_name DmModels
extends RefCounted
## GLB loading + the web game's height normalisation (AssetCache.model: scale to a target height, stand on the ground, centre on x/z).
## GLBs are the web's models, dequantized by tools/godot/sync-slice-assets.mjs (Godot's importer rejects KHR_mesh_quantization).

const BASE := "res://assets/slice/"
static var _info: Dictionary = {}
## Models read from disk because nothing had loaded them yet (tests: a warmed game's tour must leave this at 0).
static var cold_loads := 0

static func _rel(root: Node, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf

## Analyse a model once: scale/offset that normalise it, plus its mesh parts (non-skinned) for MultiMesh batching.
static func analyze(url: String, height: float) -> Dictionary:
	var key := "%s@%s" % [url, height]
	if _info.has(key):
		return _info[key]
	if not ResourceLoader.has_cached(BASE + url):
		cold_loads += 1
	var ps: PackedScene = load(BASE + url)
	var root: Node3D = ps.instantiate()
	var skel: Skeleton3D = null
	for sk in root.find_children("*", "Skeleton3D", true, false):
		skel = sk
	var parts: Array = []
	var bb := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var m := n as MeshInstance3D
		if m.mesh == null:
			continue
		var xf := _rel(root, m)
		if m.skin != null and skel != null and m.skin.get_bind_count() > 0:
			# glTF skinning: rest-pose world = jointRest * inverseBind * v. The quantization scale lives in the inverse binds.
			var bi := 0
			var bone := m.skin.get_bind_bone(bi)
			if bone < 0:
				bone = skel.find_bone(m.skin.get_bind_name(bi))
			xf = _rel(root, skel) * skel.get_bone_global_rest(bone) * m.skin.get_bind_pose(bi)
		var box: AABB = xf * m.mesh.get_aabb()
		bb = box if first else bb.merge(box)
		first = false
		parts.append({"mesh": m.mesh, "xf": xf})
	root.free()
	var s := height / maxf(bb.size.y, 0.0001)
	var c := bb.get_center()
	var info := {"scene": ps, "scale": s, "cx": c.x, "cz": c.z, "miny": bb.position.y, "parts": parts, "skinned": skel != null, "prepped": false}
	_info[key] = info
	return info

## Parts of a static prop ready for MultiMesh: {mesh, local: Transform3D} where local already includes normalisation.
static func prop_parts(url: String, height: float) -> Array:
	var inf := analyze(url, height)
	var s: float = inf.scale
	var norm := Transform3D(Basis.from_scale(Vector3.ONE * s), Vector3(-inf.cx * s, -inf.miny * s, -inf.cz * s))
	var out: Array = []
	for p in inf.parts:
		out.append({"mesh": p.mesh, "local": norm * p.xf})
	return out

## A creature from a model entry of enemies.json/npcs.json/hero.json (url, height, yaw, stride, timings): {root, anim, animator}.
static func creature_from(entry: Dictionary, scale: float = 1.0) -> Dictionary:
	var h: float = float(entry.height) * scale
	var c := creature(entry.url, h, float(entry.yaw))
	c["animator"] = DmAnimator.new(c.anim, entry, h)
	return c

## A walking/animated model: returns {root: Node3D (feet at y=0, +Z forward), anim: AnimationPlayer or null}.
static func creature(url: String, height: float, yaw: float) -> Dictionary:
	var inf := analyze(url, height)
	var s: float = inf.scale
	var holder := Node3D.new()
	var yawer := Node3D.new()
	yawer.rotation.y = yaw
	holder.add_child(yawer)
	var model: Node3D = (inf.scene as PackedScene).instantiate()
	model.scale = Vector3.ONE * s
	model.position = Vector3(-inf.cx * s, -inf.miny * s, -inf.cz * s)
	yawer.add_child(model)
	var ap: AnimationPlayer = null
	for a in model.find_children("*", "AnimationPlayer", true, false):
		ap = a
	if ap != null and not inf.prepped:
		_prep_anims(ap)
		inf.prepped = true
	return {"root": holder, "anim": ap}

## Loop idle/walk/run and strip root travel (the web's stripRootTravel / inPlace clips): remove the linear drift of the root/hip position track.
static func _prep_anims(ap: AnimationPlayer) -> void:
	for nm in ap.get_animation_list():
		var a := ap.get_animation(nm)
		if nm in ["idle", "walk", "run", "channel"]:
			a.loop_mode = Animation.LOOP_LINEAR
		else:
			a.loop_mode = Animation.LOOP_NONE
		for i in a.get_track_count():
			if a.track_get_type(i) != Animation.TYPE_POSITION_3D or a.track_get_key_count(i) < 2:
				continue
			var path := str(a.track_get_path(i))
			var bone := path.get_slice(":", 1)
			if not (bone == "Hip" or bone.ends_with("Root")):
				continue
			var n := a.track_get_key_count(i)
			var v0: Vector3 = a.track_get_key_value(i, 0)
			var v1: Vector3 = a.track_get_key_value(i, n - 1)
			var t1 := a.track_get_key_time(i, n - 1)
			if t1 <= 0.0:
				continue
			if not (nm in ["walk", "run"]):
				continue
			for k in n:
				var v: Vector3 = a.track_get_key_value(i, k)
				var f := a.track_get_key_time(i, k) / t1
				a.track_set_key_value(i, k, v - (v1 - v0) * f)

static func play(ap: AnimationPlayer, anim: String, speed: float = 1.0, blend: float = 0.15) -> void:
	if ap == null or not ap.has_animation(anim):
		return
	if ap.current_animation == anim and ap.is_playing():
		ap.speed_scale = speed
		return
	ap.play(anim, blend, speed)
