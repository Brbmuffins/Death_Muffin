class_name DmDrawModel
extends RefCounted
## The 3D draw calls of a scene, counted from data (client/README.md "The draw budget"). `record` describes one geometry instance and `facts` the camera and the moon;
## `count` works out from them what Forward+ issues for one frame, so a test can hold the number (a draw call is what the budget counts, and a headless run draws nothing).
##
## What the model knows about the renderer, each part measured in a rendered Forward+ run (`client/tools/draw_measure.gd`, 2026-10-17, and the benchmark runs on Helix's PC):
##  - an instance is an object in the main pass when its bounds meet the camera's frustum (and its visibility range), and in a shadow pass once for each moon cascade whose volume its bounds
##    meet, when it casts; a draw call is one surface of an object;
##  - the renderer draws the instances of one mesh, surface and material that it meets in a pass in ONE instanced draw call (a prop that stands a hundred times costs what it costs once);
##    a mesh that stands once costs its surfaces (merging props into cell meshes made each unique and cost draw calls: client/README.md "Static batching is not in the areas");
##  - a MultiMesh is never merged and costs its surfaces in each pass **whether or not it holds an instance** (`visible_instance_count` 0 still draws): the crowd hides a group while it is empty;
##  - what it leaves out: occlusion culling (the Graves' occluders), the lights' and the sky's own passes, and anything outside the scene tree it is given. Its numbers run a few draws
##    under the engine's (110 against 106 for the Graves' world), so a budget is set a little above the model's number, not at it.

const ASPECT := 16.0 / 9.0   ## the benchmark's picture (2560x1440): the camera's width follows from its height and this


## One geometry instance as the model needs it (a plain dictionary, so a measurement can write it to a file). `game` is the root the instance's path is taken from.
static func record(nd: GeometryInstance3D, game: Node) -> Dictionary:
	var rec := {"p": String(game.get_path_to(nd)), "t": nd.get_class(), "cat": DmBenchmark._part_of(nd), "vis": nd.is_visible_in_tree(), "cs": int(nd.cast_shadow),
		"ve": nd.visibility_range_end, "s": 0, "n": -1}
	var local := nd.get_aabb()
	var mesh: Mesh = null
	if nd is MeshInstance3D:
		mesh = (nd as MeshInstance3D).mesh
		var am := mesh as ArrayMesh
		if am != null and am.custom_aabb.size != Vector3.ZERO:
			local = am.custom_aabb   # (the weather's mesh keeps its vertices at the origin and says how far they reach)
	elif nd is MultiMeshInstance3D and (nd as MultiMeshInstance3D).multimesh != null:
		var mm := (nd as MultiMeshInstance3D).multimesh
		mesh = mm.mesh
		rec["n"] = mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
		if mm.custom_aabb.size != Vector3.ZERO:
			local = mm.custom_aabb   # (a headless run keeps no instance data to measure)
		var view := nd.get_parent() as CrowdView
		if view != null:
			var parts := nd.name.split("_lod")   # "<slug>_lod<N>[_shadow|_fade]"
			if parts.size() == 2 and view.model_slots().has(String(parts[0])):
				rec["model"] = String(parts[0])
				rec["lod"] = int(parts[1])
				rec["n"] = int(view.crowd.instance_count(int(view.model_slots()[String(parts[0])]), int(parts[1]), String(parts[1]).ends_with("_shadow"), String(parts[1]).ends_with("_fade")))   # (what the crowd drew)
	var ab := nd.global_transform * local.grow(nd.extra_cull_margin)
	rec["ab"] = [ab.position.x, ab.position.y, ab.position.z, ab.size.x, ab.size.y, ab.size.z]
	if mesh != null:
		rec["s"] = mesh.get_surface_count()
		rec["mesh"] = mesh.get_rid().get_id()
		var mats: Array = []
		for i in mesh.get_surface_count():
			var m: Material = nd.material_override if nd.material_override != null else (nd.get_active_material(i) if nd is MeshInstance3D else mesh.surface_get_material(i))
			mats.append(m.get_rid().get_id() if m != null else 0)
		rec["mat"] = mats
	rec["grp"] = _group(nd, rec)
	return rec


## The group a record belongs to, for a budget's rows and a measurement's steps: "crowd:lod0:shadow:used", "world:Props", "other:<first two path segments>", ...
static func _group(nd: GeometryInstance3D, rec: Dictionary) -> String:
	if _is_dressing(nd):
		return "dressing:" + String(nd.name)
	if nd.get_parent() is CrowdView:
		return "crowd:lod%d:%s:%s" % [int(rec.get("lod", 0)), "shadow" if String(nd.name).ends_with("_shadow") else ("fade" if String(nd.name).ends_with("_fade") else "plain"), "used" if int(rec["n"]) > 0 else "empty"]
	var path := String(rec["p"])
	if rec["cat"] == "World":
		var i := path.find("area_")   # area_graves/Props/...: the segment below the area
		if i >= 0:
			var rest := path.substr(i).split("/")
			return "world:" + String(rest[1]) if rest.size() >= 2 else "world:area"
		return "world:" + "/".join(path.split("/").slice(0, 2))
	return "other:" + "/".join(path.split("/").slice(0, 2))


## The world dressing's own pieces (DmWorldDressing's children and the flames and windows it puts under the area scenes, which it marks): group "dressing:<piece>", counted apart from the area.
static func _is_dressing(nd: Node) -> bool:
	if nd.has_meta("dressing"):
		return true
	var p := nd.get_parent()
	while p != null:
		if p is DmWorldDressing:
			return true
		p = p.get_parent()
	return false


## Every geometry instance under `root`, as records.
static func records(root: Node, game: Node) -> Array:
	var out: Array = []
	var st: Array[Node] = [root]
	while not st.is_empty():
		var nd: Node = st.pop_back()
		for c in nd.get_children():
			st.append(c)
		if nd is GeometryInstance3D:
			out.append(record(nd, game))
	return out


## The camera and the moon, from the scene (the frustum is worked out from the camera's fov, near, far and `aspect`, not read from a viewport: a headless run has none).
static func facts(game: Node, cam: Camera3D, aspect := ASPECT) -> Dictionary:
	var t := cam.global_transform
	var f := {"aspect": aspect, "camera": {"origin": t.origin, "basis": t.basis, "fov": cam.fov, "near": cam.near, "far": cam.far, "planes": frustum(t, cam.fov, cam.near, cam.far, aspect)}}
	var st: Array[Node] = [game]
	while not st.is_empty():
		var nd: Node = st.pop_back()
		for c in nd.get_children():
			st.append(c)
		var l := nd as DirectionalLight3D
		if l != null and l.shadow_enabled and l.is_visible_in_tree():
			f["moon"] = {"dir": -l.global_transform.basis.z, "mode": int(l.directional_shadow_mode), "max": l.directional_shadow_max_distance,
				"split1": l.directional_shadow_split_1, "split2": l.directional_shadow_split_2, "split3": l.directional_shadow_split_3}
	return f


## A perspective camera's six planes as [nx, ny, nz, d] with the normals pointing out (`Camera3D.get_frustum()`'s): near, far, left, right, top, bottom.
static func frustum(t: Transform3D, fov: float, near: float, far: float, aspect: float) -> Array:
	var fwd := -t.basis.z
	var th := tan(deg_to_rad(fov) * 0.5)
	var tw := th * aspect
	var o := t.origin
	var out: Array = []
	for pair: Array in [[-fwd, o + fwd * near], [fwd, o + fwd * far], [(-t.basis.x - fwd * tw).normalized(), o], [(t.basis.x - fwd * tw).normalized(), o],
			[(t.basis.y - fwd * th).normalized(), o], [(-t.basis.y - fwd * th).normalized(), o]]:
		var n: Vector3 = pair[0]
		out.append([n.x, n.y, n.z, n.dot(pair[1])])
	return out


# ---- the count ----------------------------------------------------------------------------------------------------------------------------

## What Forward+ draws for `recs` under `facts`. Returns {groups: {group: counts}, total: counts, cascades: n}; counts are {main_objs, main_draws, shadow_objs, shadow_draws, instances}.
static func count(recs: Array, facts: Dictionary) -> Dictionary:
	var cam: Dictionary = facts["camera"]
	var planes: Array = cam["planes"]
	var origin: Vector3 = cam["origin"]
	var volumes: Array = cascades(facts) if facts.has("moon") else []
	var groups := {}
	var keys := {"main": {}, "shadow": {}}   # pass -> {mesh:surface:material: true}: the draws the renderer's instancing leaves
	var gkeys := {}                          # group -> the same
	var total := {"main_objs": 0, "main_draws": 0, "shadow_objs": 0, "shadow_draws": 0}
	for r: Dictionary in recs:
		if not bool(r["vis"]) or int(r["s"]) == 0:
			continue
		var ab: Array = r["ab"]
		var box := AABB(Vector3(ab[0], ab[1], ab[2]), Vector3(ab[3], ab[4], ab[5]))
		var grp: String = r["grp"]
		var g: Dictionary = groups.get(grp, {"main_objs": 0, "main_draws": 0, "shadow_objs": 0, "shadow_draws": 0, "instances": 0})
		var gk: Dictionary = gkeys.get(grp, {"main": {}, "shadow": {}})
		g["instances"] += 1
		var cs := int(r["cs"])   # 0 off, 1 on, 2 double-sided, 3 shadows only
		var ve := float(r["ve"])
		var in_range := ve <= 0.0 or box.get_center().distance_to(origin) <= ve
		var multi := int(r["n"]) >= 0
		var mats: Array = r.get("mat", [])
		if cs != 3 and in_range and in_frustum(box, planes):
			g["main_objs"] += 1
			_surfaces(r, mats, multi, "main", 1, keys, gk, g, total, "main_draws")
		if cs != 0 and in_range:
			var hits := 0
			for v: Dictionary in volumes:
				if in_cascade(box, v):
					hits += 1
			if hits > 0:
				g["shadow_objs"] += hits
				_surfaces(r, mats, multi, "shadow", hits, keys, gk, g, total, "shadow_draws")
		groups[grp] = g
		gkeys[grp] = gk
	for g: Dictionary in groups.values():
		total["main_objs"] += g["main_objs"]
		total["shadow_objs"] += g["shadow_objs"]
	for grp: String in groups:
		groups[grp]["main_draws"] += gkeys[grp]["main"].size()
		groups[grp]["shadow_draws"] += gkeys[grp]["shadow"].size()
	total["main_draws"] += keys["main"].size()
	total["shadow_draws"] += keys["shadow"].size()
	return {"groups": groups, "total": total, "cascades": volumes.size()}


## The draws of one object's surfaces in a pass: a MultiMesh's at once (`times` for each cascade it meets), a plain mesh's by key.
static func _surfaces(r: Dictionary, mats: Array, multi: bool, pass_: String, times: int, keys: Dictionary, gk: Dictionary, g: Dictionary, total: Dictionary, field: String) -> void:
	if multi:
		g[field] += int(r["s"]) * times
		total[field] += int(r["s"]) * times
		return
	for i in int(r["s"]):
		var key := "%d:%d:%d" % [int(r.get("mesh", 0)), i, int(mats[i]) if i < mats.size() else 0]
		keys[pass_][key] = true
		gk[pass_][key] = true


## The sum of a counts dictionary's draws, both passes.
static func draws(counts: Dictionary) -> int:
	return int(counts["main_draws"]) + int(counts["shadow_draws"])


## The frustum test: false when the box lies wholly outside one plane.
static func in_frustum(box: AABB, planes: Array) -> bool:
	for p: Array in planes:
		var n := Vector3(p[0], p[1], p[2])
		if n.dot(box.get_support(-n)) > float(p[3]):
			return false
	return true


## The moon's cascades as light-space boxes {right, up, dir, x0, x1, y0, y1, z1}: the slice of the camera's frustum between two distances (`max` and the splits), its corners' bounds
## across the light, and how far along the light's travel it reaches; a caster on the light's side of it is kept (the renderer pushes the near plane out).
static func cascades(facts: Dictionary) -> Array:
	var cam: Dictionary = facts["camera"]
	var moon: Dictionary = facts["moon"]
	var b: Basis = cam["basis"]
	var o: Vector3 = cam["origin"]
	var fwd := -b.z
	var tan_h := tan(deg_to_rad(float(cam["fov"])) * 0.5)
	var far_d := minf(float(moon["max"]) if float(moon["max"]) > 0.0 else float(cam["far"]), float(cam["far"]))
	var near_d := minf(float(cam["near"]), far_d)
	var splits: Array = [1.0]
	if int(moon["mode"]) == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS:
		splits = [float(moon["split1"]), 1.0]
	elif int(moon["mode"]) == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS:
		splits = [float(moon["split1"]), float(moon["split2"]), float(moon["split3"]), 1.0]
	var dir: Vector3 = (moon["dir"] as Vector3).normalized()
	var lr := dir.cross(Vector3.UP).normalized()
	var lu := lr.cross(dir).normalized()
	var out: Array = []
	var d0 := near_d
	for s: float in splits:
		var d1 := near_d + s * (far_d - near_d)
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for d: float in [d0, d1]:
			for sx: float in [-1.0, 1.0]:
				for sy: float in [-1.0, 1.0]:
					var p := o + fwd * d + b.x * (sx * d * tan_h * float(facts["aspect"])) + b.y * (sy * d * tan_h)
					var q := Vector3(p.dot(lr), p.dot(lu), p.dot(dir))
					lo = lo.min(q)
					hi = hi.max(q)
		out.append({"right": lr, "up": lu, "dir": dir, "x0": lo.x, "x1": hi.x, "y0": lo.y, "y1": hi.y, "z1": hi.z})
		d0 = d1
	return out


static func in_cascade(box: AABB, v: Dictionary) -> bool:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in 8:
		var p := box.get_endpoint(i)
		var q := Vector3(p.dot(v["right"]), p.dot(v["up"]), p.dot(v["dir"]))
		lo = lo.min(q)
		hi = hi.max(q)
	return hi.x >= float(v["x0"]) and lo.x <= float(v["x1"]) and hi.y >= float(v["y0"]) and lo.y <= float(v["y1"]) and lo.z <= float(v["z1"])
