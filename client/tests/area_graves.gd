extends SceneTree
## The rebuilt Hollow Graves (client/areas/graves.tscn) matches what today's runtime builder (godot/world/world_builder.gd) makes for the
## Graves. Every expected number is computed here from godot/data/slice/world.json the way world_builder.gd computes it, never read from the
## scene. Run: godot --headless --path client --script res://tests/area_graves.gd

const Build := preload("res://tools/build_area.gd")
const AREA := "graves"
const SCENE := "res://areas/graves.tscn"
const EPS := 0.0005

var _pass := 0
var _fail := 0
var _world: Dictionary
var _scene: Node3D


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL area_graves: ", what)


func _initialize() -> void:
	_run.call_deferred()


func _finish() -> void:
	if _scene != null:
		root.remove_child(_scene)
		_scene.free()
	if _fail > 0:
		printerr("FAIL area_graves: %d of %d checks failed" % [_fail, _pass + _fail])
	else:
		print("PASS area_graves (%d checks)" % _pass)
	quit(1 if _fail > 0 else 0)


func _near(a: float, b: float) -> bool:
	return absf(a - b) <= EPS


func _near_v(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) <= EPS


func _near_t(a: Transform3D, b: Transform3D) -> bool:
	return a.origin.distance_to(b.origin) <= EPS and a.basis.x.distance_to(b.basis.x) <= EPS and a.basis.y.distance_to(b.basis.y) <= EPS and a.basis.z.distance_to(b.basis.z) <= EPS


func _hex(v: Variant) -> Color:
	return Color.hex(int(v) * 256 + 255)


func _in_area(rect: Dictionary, x: float, z: float) -> bool:
	return x >= rect.x0 and x <= rect.x1 and z >= rect.z0 and z <= rect.z1


func _center_in_area(r: Dictionary) -> bool:
	return _in_area(_world.areas[AREA].rect, (float(r.x0) + float(r.x1)) / 2.0, (float(r.z0) + float(r.z1)) / 2.0)


func _kids(path: String) -> Array[Node]:
	var n := _scene.get_node_or_null(path)
	var out: Array[Node] = []
	if n != null:
		out.assign(n.get_children())
	return out


func _sig(parts: Array) -> String:
	var out := ""
	for p: Variant in parts:
		out += ("%.3f" % p) if (p is float) else str(p)
		out += "|"
	return out


func _run() -> void:
	var text := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://").path_join("../godot/data/slice/world.json"))
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		printerr("FAIL area_graves: cannot read godot/data/slice/world.json")
		quit(1)
		return
	_world = parsed
	if not ResourceLoader.exists(SCENE):
		printerr("FAIL area_graves: %s is missing (run tools/rebuild/build-areas.sh graves)" % SCENE)
		quit(1)
		return
	_scene = (load(SCENE) as PackedScene).instantiate()
	root.add_child(_scene)
	var area: Dictionary = _world.areas[AREA]
	var rect: Dictionary = area.rect

	_check(_scene.name == AREA and _scene.get_meta("area_id") == AREA, "root is the area '%s'" % AREA)
	for g in ["Floor", "Walls", "Props", "GatherNodes", "Decals", "Water", "Doors", "Lights", "Occluders", "Colliders", "Navigation"]:
		_check(_scene.has_node(g), "group %s exists" % g)

	_test_floor(area, rect)
	_test_walls()
	_test_props()
	_test_nodes()
	_test_decals_water()
	_test_lights()
	_test_colliders()
	_test_occluders()
	_test_doors(rect)
	await _test_navigation(rect)
	_test_bounds(rect)
	_finish()


# ---------------------------------------------------------------- floors
func _test_floor(area: Dictionary, rect: Dictionary) -> void:
	var f: Dictionary = _world.floors[area.theme]
	var ground := _scene.get_node("Floor/ground") as MeshInstance3D
	var box := ground.mesh.get_aabb()
	var cx := (ground.position.x)
	var cz := (ground.position.z)
	_check(_near(cx + box.position.x, rect.x0 - 0.8) and _near(cx + box.end.x, rect.x1 + 0.8)
		and _near(cz + box.position.z, rect.z0 - 0.8) and _near(cz + box.end.z, rect.z1 + 0.8), "ground covers the rect plus 0.8 m on every side")
	_check(_near(ground.position.y, 0.0), "ground at y 0")
	var mat := ground.material_override as StandardMaterial3D
	_check(mat != null and mat.albedo_texture.resource_path == "res://assets/slice/art/textures/%s.webp" % f.tex, "ground texture is the %s floor texture" % f.tex)
	_check(mat != null and mat.albedo_color.is_equal_approx(_hex(f.color)) and _near(mat.roughness, float(f.rough)), "ground colour and roughness")
	# World-anchored UVs: the vertex at the rect's first corner has UV = world position / tile.
	var arrays := ground.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var uv_ok := verts.size() == 4 and uvs.size() == 4
	for i in verts.size():
		var wx := verts[i].x + cx
		var wz := verts[i].z + cz
		uv_ok = uv_ok and _near(uvs[i].x, wx / float(f.tile)) and _near(uvs[i].y, wz / float(f.tile))
	_check(uv_ok, "ground UVs are anchored to world position (tile %s m)" % f.tile)
	_check(uv2.size() == verts.size(), "ground has lightmap UV2")
	_check(ground.gi_mode == GeometryInstance3D.GI_MODE_STATIC, "ground is static for baked lighting")
	# Paths whose centre lies in the area.
	var expect: Array[String] = []
	for p: Dictionary in _world.paths:
		if _center_in_area(p):
			expect.append(_sig([p.x0, p.z0, p.x1, p.z1]))
	var got: Array[String] = []
	for k in _kids("Floor"):
		if String(k.name).begins_with("path_"):
			var mi := k as MeshInstance3D
			var b := mi.mesh.get_aabb()
			got.append(_sig([mi.position.x + b.position.x, mi.position.z + b.position.z, mi.position.x + b.end.x, mi.position.z + b.end.z]))
			_check(_near(mi.position.y, 0.008), "path floor sits at y 0.008")
	expect.sort()
	got.sort()
	_check(not expect.is_empty() and expect == got, "%d path floors cover the same rects as world.json" % expect.size())


# ---------------------------------------------------------------- walls
func _nbox(b: Dictionary) -> Dictionary:
	return {"x0": minf(b.x0, b.x1), "x1": maxf(b.x0, b.x1), "z0": minf(b.z0, b.z1), "z1": maxf(b.z0, b.z1)}


func _test_walls() -> void:
	var expect: Array[String] = []
	for w: Dictionary in _world.walls:
		if w.area == AREA:
			var b := _nbox(w.box)
			expect.append(_sig([(b.x0 + b.x1) / 2.0, w.height / 2.0, (b.z0 + b.z1) / 2.0, b.x1 - b.x0, w.height, b.z1 - b.z0]))
	var got: Array[String] = []
	var tex_ok := true
	var uv2_ok := true
	var static_ok := true
	for k in _kids("Walls"):
		var mi := k as MeshInstance3D
		var bm := mi.mesh as BoxMesh
		got.append(_sig([mi.position.x, mi.position.y, mi.position.z, bm.size.x, bm.size.y, bm.size.z]))
		var mat := mi.material_override as StandardMaterial3D
		tex_ok = tex_ok and mat.uv1_triplanar and mat.albedo_texture.resource_path.ends_with("/stone_wall.webp")
		uv2_ok = uv2_ok and bm.add_uv2
		static_ok = static_ok and mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC
	expect.sort()
	got.sort()
	_check(not expect.is_empty() and expect == got, "%d wall boxes match world.json (position and size)" % expect.size())
	_check(tex_ok, "walls use the triplanar stone texture")
	_check(uv2_ok and static_ok, "walls are static with generated lightmap UV2")


# ---------------------------------------------------------------- props
## DmModels.analyze: stand the model on the ground, centred on x/z, scaled to `height`; returns {norm, parts: [{mesh, xf}]}.
func _analyze(url: String, height: float) -> Dictionary:
	var ps: PackedScene = load("res://assets/slice/" + url)
	var tmp: Node3D = ps.instantiate()
	var parts: Array = []
	var bb := AABB()
	var first := true
	for n in tmp.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var cur: Node = mi
		while cur != null and cur != tmp:
			if cur is Node3D:
				xf = (cur as Node3D).transform * xf
			cur = cur.get_parent()
		var box: AABB = xf * mi.mesh.get_aabb()
		bb = box if first else bb.merge(box)
		first = false
		parts.append({"name": String(mi.name), "xf": xf})
	tmp.free()
	var s := height / maxf(bb.size.y, 0.0001)
	var c := bb.get_center()
	return {"norm": Transform3D(Basis.from_scale(Vector3.ONE * s), Vector3(-c.x * s, -bb.position.y * s, -c.z * s)), "parts": parts}


func _placement(p: Dictionary) -> Transform3D:
	var tilt: float = p.tilt
	return Transform3D(Basis.from_euler(Vector3(tilt, p.rot, tilt * 0.6), EULER_ORDER_XYZ) * Basis.from_scale(Vector3.ONE * float(p.scale)), Vector3(p.x, p.y, p.z))


func _test_props() -> void:
	var by_kind: Dictionary = {}
	var list: Array = []
	for p: Dictionary in _world.props:
		if p.area == AREA:
			list.append(p)
			by_kind[p.prop] = int(by_kind.get(p.prop, 0)) + 1
	var got_kind: Dictionary = {}
	for k in _kids("Props"):
		var kind := String(k.get_meta("prop_kind", ""))
		got_kind[kind] = int(got_kind.get(kind, 0)) + 1
	_check(not list.is_empty(), "world.json has Graves props (%d)" % list.size())
	_check(got_kind == by_kind, "prop count per kind matches world.json (%d kinds, %d props)" % [by_kind.size(), list.size()])

	var idx: Dictionary = {}
	var place_ok := true
	var prefab_ok := true
	var mesh_ok := true
	var range_ok := true
	var static_ok := true
	var uv2_ok := true
	var analysed: Dictionary = {}
	var small_n := 0
	var meshes_n := 0
	for p: Dictionary in list:
		var kind: String = p.prop
		var i: int = idx.get(kind, 0)
		idx[kind] = i + 1
		var spec: Dictionary = _world.propSpecs[kind]
		var node := _scene.get_node_or_null("Props/%s_%03d" % [kind, i]) as Node3D
		if node == null:
			place_ok = false
			printerr("  missing prop node ", kind, i)
			continue
		var want := _placement(p)
		place_ok = place_ok and _near_t(node.transform, want)
		prefab_ok = prefab_ok and node.scene_file_path.begins_with("res://areas/props/")
		var key := "%s@%s" % [spec.url, spec.height]
		if not analysed.has(key):
			analysed[key] = _analyze(spec.url, float(spec.height))
		var info: Dictionary = analysed[key]
		var small: bool = float(spec.height) <= Build.SMALL_PROP_MAX_HEIGHT
		if small:
			small_n += 1
		# Every mesh of the glTF sits where DmModels.prop_parts puts it: placement x normalisation x its own transform.
		for part: Dictionary in info.parts:
			var mi := node.find_child(part.name, true, false) as MeshInstance3D
			if mi == null:
				mesh_ok = false
				continue
			meshes_n += 1
			mesh_ok = mesh_ok and _near_t(mi.global_transform, want * (info.norm as Transform3D) * (part.xf as Transform3D))
			static_ok = static_ok and mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC
			var arrays := mi.mesh.surface_get_arrays(0)
			uv2_ok = uv2_ok and (arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array).size() > 0
			if small:
				range_ok = range_ok and _near(mi.visibility_range_end, Build.SMALL_PROP_VISIBLE_END) and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			else:
				range_ok = range_ok and mi.visibility_range_end == 0.0 and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_check(place_ok, "every prop is placed with world_builder's transform (position, yaw, tilt, scale)")
	_check(prefab_ok, "props are instances of the per-model prefabs in areas/props")
	_check(mesh_ok and meshes_n >= list.size(), "%d prop meshes sit where DmModels.prop_parts puts them" % meshes_n)
	_check(small_n > 0 and range_ok, "%d small props (up to %s m) have a visibility range and no shadow, the %d tall ones none" % [small_n, Build.SMALL_PROP_MAX_HEIGHT, list.size() - small_n])
	_check(static_ok and uv2_ok, "prop meshes are static for baked lighting and carry lightmap UV2")


# ---------------------------------------------------------------- gathering nodes
func _test_nodes() -> void:
	var expect := 0
	var ok := true
	for n: Dictionary in _world.nodes:
		if n.area != AREA:
			continue
		expect += 1
		var holder := _scene.get_node_or_null("GatherNodes/%s" % n.id) as Node3D
		if holder == null:
			ok = false
			continue
		ok = ok and _near_v(holder.position, Vector3(n.x, 0.04, n.z)) and holder.basis.is_equal_approx(Basis(Vector3.UP, float(n.rot)))
		var model := holder.get_node_or_null("model") as Node3D
		ok = ok and model != null and model.scene_file_path.begins_with("res://areas/props/")
		if model != null:
			var info := _analyze(n.model, float(n.modelHeight))
			ok = ok and _near_t((model.get_child(0) as Node3D).transform, info.norm)
	_check(expect > 0 and ok and _kids("GatherNodes").size() == expect, "%d gathering nodes stand where world.json puts them, with their normalised model" % expect)


# ---------------------------------------------------------------- decals, puddles, water
func _test_decals_water() -> void:
	var cracks := 0
	var sigils := 0
	var expect: Array[String] = []
	for d: Dictionary in _world.decals:
		if d.area == AREA:
			if d.kind == "sigil":
				sigils += 1
			else:
				cracks += 1
			expect.append(_sig([d.kind, d.x, 0.03 if d.kind == "sigil" else 0.02, d.z, d.r * 2.0, sin(d.rot), cos(d.rot)]))
	var puddles: Array[String] = []
	for p: Dictionary in _world.puddles:
		if p.area == AREA:
			puddles.append(_sig([p.x, p.z, p.r * 2.0 * float(p.sx), p.r * 2.0, sin(p.rot), cos(p.rot)]))
	var got: Array[String] = []
	var got_p: Array[String] = []
	var flat_ok := true
	for k in _kids("Decals"):
		var mi := k as MeshInstance3D
		var qm := mi.mesh as QuadMesh
		flat_ok = flat_ok and qm.orientation == PlaneMesh.FACE_Y and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if String(k.name).begins_with("puddle_"):
			got_p.append(_sig([mi.position.x, mi.position.z, qm.size.x, qm.size.y, sin(mi.rotation.y), cos(mi.rotation.y)]))
		else:
			var kind := "sigil" if String(k.name).begins_with("sigil") else "cracks"
			got.append(_sig([kind, mi.position.x, mi.position.y, mi.position.z, qm.size.x, sin(mi.rotation.y), cos(mi.rotation.y)]))
	expect.sort()
	got.sort()
	puddles.sort()
	got_p.sort()
	_check(cracks > 0 and sigils > 0 and expect == got, "%d crack and %d sigil decals match world.json (kind, place, size, yaw)" % [cracks, sigils])
	_check(not puddles.is_empty() and puddles == got_p, "%d puddles match world.json" % puddles.size())
	_check(flat_ok, "decals and puddles are flat quads that cast no shadow")
	# Water, bog and ponds belong to the area their rect lies in: none of them lies in the Graves.
	var water_here := 0
	for list_name in ["water", "bog", "ponds"]:
		for r: Dictionary in _world[list_name]:
			if _center_in_area(r):
				water_here += 1
	_check(water_here == 0 and _kids("Water").size() == 0, "the Graves have no water (world.json: %d rects here, scene: %d)" % [water_here, _kids("Water").size()])


# ---------------------------------------------------------------- lights
func _test_lights() -> void:
	const POINT_K := 0.18
	var expect: Array[String] = []
	var pools := 0
	for p: Dictionary in _world.props:
		if p.area != AREA:
			continue
		var spec: Dictionary = _world.propSpecs[p.prop]
		if spec.has("light") and spec.light != null:
			var L: Dictionary = spec.light
			var c := _hex(L.color)
			expect.append(_sig([p.x, float(L.y) * float(p.scale) + float(p.y), p.z, float(L.distance), float(L.intensity) * POINT_K, c.r, c.g, c.b]))
			pools += 1
	var got: Array[String] = []
	var bake_ok := true
	var other := 0
	for k in _kids("Lights"):
		if k is OmniLight3D:
			var l := k as OmniLight3D
			got.append(_sig([l.position.x, l.position.y, l.position.z, l.omni_range, l.light_energy, l.light_color.r, l.light_color.g, l.light_color.b]))
			bake_ok = bake_ok and l.light_bake_mode == Light3D.BAKE_STATIC and _near(l.omni_attenuation, 1.3)
		else:
			other += 1
	expect.sort()
	got.sort()
	_check(not expect.is_empty() and expect == got, "%d prop lights match world.json (place, range, energy, colour)" % expect.size())
	_check(bake_ok, "prop lights are static-bake placeholders")
	_check(other == 1 and _scene.has_node("Lights/light_pools"), "one light-pool mesh (%d pools) lies under the flames" % pools)
	var pool_mesh := (_scene.get_node("Lights/light_pools") as MeshInstance3D).mesh
	_check((pool_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == pools * 6, "the light-pool mesh has two triangles per flame")


# ---------------------------------------------------------------- colliders
func _test_colliders() -> void:
	var expect: Array[String] = []
	var walls := 0
	var circles := 0
	var boxes := 0
	var node_cols := 0
	for w: Dictionary in _world.walls:
		if w.area == AREA:
			var b := _nbox(w.box)
			var h := maxf(float(w.height), 3.0)
			expect.append(_sig(["box", b.x1 - b.x0, h, b.z1 - b.z0, (b.x0 + b.x1) / 2.0, h / 2.0, (b.z0 + b.z1) / 2.0]))
			walls += 1
	for p: Dictionary in _world.props:
		if p.area != AREA or p.obstacle == null:
			continue
		var o: Dictionary = p.obstacle
		if o.kind == "circle":
			expect.append(_sig(["cyl", o.r, 3.0, o.x, 1.5, o.z]))
			circles += 1
		else:
			expect.append(_sig(["box", o.x1 - o.x0, 3.0, o.z1 - o.z0, (o.x0 + o.x1) / 2.0, 1.5, (o.z0 + o.z1) / 2.0]))
			boxes += 1
	for n: Dictionary in _world.nodes:
		if n.area == AREA and float(n.collider) > 0.0:
			expect.append(_sig(["cyl", float(n.collider), 3.0, n.x, 1.5, n.z]))
			node_cols += 1
	for r: Dictionary in _world.ponds:
		if _center_in_area(r):
			expect.append(_sig(["box", r.x1 - r.x0, 3.0, r.z1 - r.z0, (r.x0 + r.x1) / 2.0, 1.5, (r.z0 + r.z1) / 2.0]))
	var body := _scene.get_node("Colliders") as StaticBody3D
	var got: Array[String] = []
	for k in body.get_children():
		var cs := k as CollisionShape3D
		if cs.shape is BoxShape3D:
			var s := (cs.shape as BoxShape3D).size
			got.append(_sig(["box", s.x, s.y, s.z, cs.position.x, cs.position.y, cs.position.z]))
		elif cs.shape is CylinderShape3D:
			var c := cs.shape as CylinderShape3D
			got.append(_sig(["cyl", c.radius, c.height, cs.position.x, cs.position.y, cs.position.z]))
	expect.sort()
	got.sort()
	_check(expect == got, "%d static colliders match world.json: %d walls, %d round + %d box props, %d nodes" % [expect.size(), walls, circles, boxes, node_cols])
	_check(body.collision_layer == 1 and body is StaticBody3D, "colliders are one static body on the 'world' layer")


# ---------------------------------------------------------------- occluders
func _test_occluders() -> void:
	var expect := 0
	for w: Dictionary in _world.walls:
		if w.area == AREA:
			var b := _nbox(w.box)
			if float(w.height) >= Build.OCC_WALL_MIN_HEIGHT and maxf(b.x1 - b.x0, b.z1 - b.z0) >= Build.OCC_WALL_MIN_LENGTH:
				expect += 1
	var big := 0
	for p: Dictionary in _world.props:
		if p.area != AREA:
			continue
		var spec: Dictionary = _world.propSpecs[p.prop]
		var c: Variant = spec.get("collider")
		if c != null and c.kind == "box" and float(spec.height) * float(p.scale) >= Build.OCC_PROP_MIN_HEIGHT and minf(float(c.hw), float(c.hd)) * 2.0 * float(p.scale) >= Build.OCC_PROP_MIN_SIDE:
			big += 1
	var occ := _kids("Occluders")
	var inside := true
	for k in occ:
		var oi := k as OccluderInstance3D
		var bo := oi.occluder as BoxOccluder3D
		# Never larger than the real mausoleum footprint, and standing on the ground.
		inside = inside and bo != null and bo.size.y <= 5.2 and _near(oi.position.y, bo.size.y / 2.0)
	_check(big > 0 and occ.size() == expect + big, "%d occluders: %d tall walls (the Graves' walls are knee-high) and %d large solid props" % [occ.size(), expect, big])
	_check(inside, "occluders are smaller than their props and stand on the ground")
	_check(ProjectSettings.get_setting("rendering/occlusion_culling/use_occlusion_culling", false) == true, "occlusion culling is on in the project")


# ---------------------------------------------------------------- doors and gates
func _test_doors(rect: Dictionary) -> void:
	var touching: Array[String] = []
	var gated: Array[String] = []
	var ok := true
	for d: Dictionary in _world.doors:
		if d.a != AREA and d.b != AREA:
			continue
		touching.append(d.id)
		var holder := _scene.get_node_or_null("Doors/%s" % d.id) as Node3D
		if holder == null:
			ok = false
			continue
		var fl := holder.get_node("floor") as MeshInstance3D
		var b := fl.mesh.get_aabb()
		ok = ok and _near(fl.position.x + b.position.x, d.rect.x0) and _near(fl.position.x + b.end.x, d.rect.x1) and _near(fl.position.z + b.position.z, d.rect.z0) and _near(fl.position.z + b.end.z, d.rect.z1) and _near(fl.position.y, 0.005)
		if d.id == "chapter_graves":
			ok = ok and not holder.has_node("gate")
			continue
		gated.append(d.id)
		var gate := holder.get_node_or_null("gate") as Node3D
		if gate == null:
			ok = false
			continue
		ok = ok and _near_v(gate.position, Vector3(d.cx, 0, d.cz)) and _near(gate.rotation.y, 0.0 if d.axis == "z" else PI / 2.0)
		var col := gate.get_node("body/collider") as CollisionShape3D
		ok = ok and (col.shape as BoxShape3D).size.is_equal_approx(Vector3(d.width, 5.0, 1.0)) and _near_v(col.position, Vector3(0, 2.5, 0))
		ok = ok and not col.disabled and gate.get_node("bars").get_child_count() == 4
		var bars := gate.get_node("bars/bars") as MultiMeshInstance3D
		ok = ok and bars.multimesh.instance_count == int(round(float(d.width) / 0.45)) + 1
	_check(touching.size() > gated.size() and not gated.is_empty() and ok, "%d doors touch the Graves (%s); %d gates start closed with a solid body" % [touching.size(), ", ".join(touching), gated.size()])
	_check(_kids("Doors").size() == touching.size(), "no door of another area is in this scene")


# ---------------------------------------------------------------- navigation
func _all_obstacles() -> Array:
	const GROW := 0.55
	var out: Array = []
	for w: Dictionary in _world.walls:
		var b := _nbox(w.box)
		out.append([b.x0, b.z0, b.x1, b.z1, PackedVector3Array([Vector3(b.x0, 0, b.z0), Vector3(b.x1, 0, b.z0), Vector3(b.x1, 0, b.z1), Vector3(b.x0, 0, b.z1)])])
	for w: Dictionary in _world.depths.walls:
		var b2 := _nbox(w.box)
		out.append([b2.x0, b2.z0, b2.x1, b2.z1, PackedVector3Array([Vector3(b2.x0, 0, b2.z0), Vector3(b2.x1, 0, b2.z0), Vector3(b2.x1, 0, b2.z1), Vector3(b2.x0, 0, b2.z1)])])
	var plist: Array = _world.props.duplicate()
	plist.append_array(_world.depths.props)
	for p: Dictionary in plist:
		var o: Variant = p.obstacle
		if o == null:
			continue
		if o.kind == "circle":
			var pts := PackedVector3Array()
			for i in 10:
				var a := TAU * i / 10.0
				pts.append(Vector3(o.x + cos(a) * (o.r + GROW), 0, o.z + sin(a) * (o.r + GROW)))
			out.append([o.x - o.r - GROW, o.z - o.r - GROW, o.x + o.r + GROW, o.z + o.r + GROW, pts])
		else:
			var x0: float = o.x0 - GROW
			var z0: float = o.z0 - GROW
			var x1: float = o.x1 + GROW
			var z1: float = o.z1 + GROW
			out.append([x0, z0, x1, z1, PackedVector3Array([Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)])])
	for n: Dictionary in _world.nodes:
		if float(n.collider) > 0.0:
			var r: float = float(n.collider) + GROW
			var pts2 := PackedVector3Array()
			for i in 10:
				var a2 := TAU * i / 10.0
				pts2.append(Vector3(n.x + cos(a2) * r, 0, n.z + sin(a2) * r))
			out.append([n.x - r, n.z - r, n.x + r, n.z + r, pts2])
	for pd: Dictionary in _world.ponds:
		var x0p: float = pd.x0 - GROW
		var z0p: float = pd.z0 - GROW
		var x1p: float = pd.x1 + GROW
		var z1p: float = pd.z1 + GROW
		out.append([x0p, z0p, x1p, z1p, PackedVector3Array([Vector3(x0p, 0, z0p), Vector3(x1p, 0, z0p), Vector3(x1p, 0, z1p), Vector3(x0p, 0, z1p)])])
	return out


## world_builder._bake_region from scratch (same settings), for comparison with the baked mesh stored in the scene.
func _fresh_bake(r: Dictionary, obstacles: Array) -> NavigationMesh:
	var src := NavigationMeshSourceGeometryData3D.new()
	var a := Vector3(r.x0, 0, r.z0)
	var b := Vector3(r.x1, 0, r.z0)
	var c := Vector3(r.x1, 0, r.z1)
	var d := Vector3(r.x0, 0, r.z1)
	src.add_faces(PackedVector3Array([a, b, c, a, c, d]), Transform3D.IDENTITY)
	for o: Array in obstacles:
		if o[2] > r.x0 - 1.5 and o[0] < r.x1 + 1.5 and o[3] > r.z0 - 1.5 and o[1] < r.z1 + 1.5:
			src.add_projected_obstruction(o[4], -0.5, 3.0, true)
	var nm := NavigationMesh.new()
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.agent_radius = 0.5
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.agent_max_slope = 45.0
	nm.region_min_size = 1.0
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	return nm


func _settle() -> void:
	var map := _scene.get_world_3d().navigation_map
	await create_timer(0.1).timeout
	NavigationServer3D.map_force_update(map)
	var last := NavigationServer3D.map_get_iteration_id(map)
	var stable := 0
	for i in 200:
		await create_timer(0.05).timeout
		var it := NavigationServer3D.map_get_iteration_id(map)
		if it == last and it > 0:
			stable += 1
			if stable >= 4:
				break
		else:
			stable = 0
			last = it


func _path_ends_near(from: Vector3, to: Vector3, tol := 1.5) -> bool:
	var p := NavigationServer3D.map_get_path(_scene.get_world_3d().navigation_map, from, to, true)
	return p.size() >= 2 and Vector2(p[p.size() - 1].x - to.x, p[p.size() - 1].z - to.z).length() < tol


func _path_length(from: Vector3, to: Vector3) -> float:
	var p := NavigationServer3D.map_get_path(_scene.get_world_3d().navigation_map, from, to, true)
	var total := 0.0
	for i in range(1, p.size()):
		total += p[i].distance_to(p[i - 1])
	return total


func _test_navigation(rect: Dictionary) -> void:
	var obstacles := _all_obstacles()
	var reg := _scene.get_node("Navigation/area_graves") as NavigationRegion3D
	var nm := reg.navigation_mesh
	_check(nm != null and nm.get_polygon_count() > 100, "the Graves' navmesh is baked into the scene with %d polygons" % (nm.get_polygon_count() if nm != null else 0))
	var fresh := _fresh_bake(rect, obstacles)
	_check(nm.get_polygon_count() == fresh.get_polygon_count() and nm.get_vertices().size() == fresh.get_vertices().size(),
		"the stored navmesh equals a fresh bake of world.json with world_builder's settings (%d polygons, %d vertices)" % [fresh.get_polygon_count(), fresh.get_vertices().size()])
	_check(_near(nm.cell_size, 0.25) and _near(nm.agent_radius, 0.5) and _near(nm.agent_height, 1.75) and _near(nm.agent_max_climb, 0.25) and _near(nm.agent_max_slope, 45.0) and _near(nm.region_min_size, 1.0),
		"navmesh settings are world_builder's")
	# Door regions and links: the always-open door is on, sealed ones start off.
	var door_ok := true
	for d: Dictionary in _world.doors:
		if d.a != AREA and d.b != AREA:
			continue
		var dr := _scene.get_node("Navigation/door_%s" % d.id) as NavigationRegion3D
		var open: bool = d.id == "chapter_graves"
		door_ok = door_ok and dr.enabled == open and dr.navigation_mesh.get_polygon_count() > 0
		var df := _fresh_bake(d.rect, obstacles)
		door_ok = door_ok and dr.navigation_mesh.get_polygon_count() == df.get_polygon_count()
		for k in 2:
			var l := _scene.get_node("Navigation/link_%s_%d" % [d.id, k]) as NavigationLink3D
			door_ok = door_ok and l.enabled == open and l.bidirectional and l.start_position.distance_to(l.end_position) < 0.5
	_check(door_ok, "door regions are baked and wired; only the always-open door starts enabled")

	# Walk it. Start of the Graves (just inside the chapterhouse door) to the King's Grave end of the yard.
	await _settle()
	var entry := Vector3(0, 0, 2)
	var far := Vector3(-14, 0, -27)
	_check(_path_ends_near(entry, far), "the yard is walkable from the chapterhouse door to the King's Grave")
	# A box prop blocks the straight line: the path bends round it and never enters its footprint.
	var blocked := false
	var detour_ok := true
	for p: Dictionary in _world.props:
		if p.area != AREA or p.obstacle == null or p.obstacle.kind != "box":
			continue
		var o: Dictionary = p.obstacle
		var zc := (float(o.z0) + float(o.z1)) / 2.0
		var a := Vector3(float(o.x0) - 2.0, 0, zc)
		var b := Vector3(float(o.x1) + 2.0, 0, zc)
		if not _in_area(rect, a.x, a.z) or not _in_area(rect, b.x, b.z):
			continue
		var path := NavigationServer3D.map_get_path(_scene.get_world_3d().navigation_map, a, b, true)
		if path.size() < 2:
			continue
		blocked = true
		for v in path:
			if v.x > o.x0 and v.x < o.x1 and v.z > o.z0 and v.z < o.z1:
				detour_ok = false
		if _path_length(a, b) <= a.distance_to(b) + 0.5:
			detour_ok = false
	_check(blocked and detour_ok, "paths bend round box props and stay out of their footprint")
	var wall_close := NavigationServer3D.map_get_closest_point(_scene.get_world_3d().navigation_map, Vector3(rect.x0 - 0.4, 0, -10))
	_check(wall_close.x > rect.x0 + 0.2, "the navmesh stops short of the outer wall (agent radius)")

	# Gates: sealed, the ossuary door blocks; open (what world_builder.set_door_open does), it is walkable.
	var inside := Vector3(22, 0, -18)
	var beyond := Vector3(34.5, 0, -18)
	_check(not _path_ends_near(inside, beyond, 1.0), "the sealed ossuary gate blocks the path")
	(_scene.get_node("Navigation/door_graves_ossuary") as NavigationRegion3D).enabled = true
	for k in 2:
		(_scene.get_node("Navigation/link_graves_ossuary_%d" % k) as NavigationLink3D).enabled = true
	await _settle()
	var reach := NavigationServer3D.map_get_path(_scene.get_world_3d().navigation_map, inside, Vector3(30, 0, -18), true)
	_check(reach.size() >= 2 and Vector2(reach[reach.size() - 1].x - 30.0, reach[reach.size() - 1].z + 18.0).length() < 1.0, "an opened gate's corridor is walkable up to the next room")


# ---------------------------------------------------------------- bounds
func _test_bounds(rect: Dictionary) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var floors: Array[Node] = _kids("Floor")
	for d in _kids("Doors"):
		floors.append(d.get_node("floor"))
	for n in floors:
		var mi := n as MeshInstance3D
		var b := mi.global_transform * mi.mesh.get_aabb()
		lo = Vector2(minf(lo.x, b.position.x), minf(lo.y, b.position.z))
		hi = Vector2(maxf(hi.x, b.end.x), maxf(hi.y, b.end.z))
	var want_lo := Vector2(rect.x0 - 0.8, rect.z0 - 0.8)
	var want_hi := Vector2(rect.x1 + 0.8, rect.z1 + 0.8)
	for d: Dictionary in _world.doors:
		if d.a == AREA or d.b == AREA:
			want_lo = Vector2(minf(want_lo.x, d.rect.x0), minf(want_lo.y, d.rect.z0))
			want_hi = Vector2(maxf(want_hi.x, d.rect.x1), maxf(want_hi.y, d.rect.z1))
	_check(lo.distance_to(want_lo) < 0.01 and hi.distance_to(want_hi) < 0.01, "floor bounds %s to %s are the rect plus 0.8 m and the door corridors" % [lo, hi])
	var inside := true
	for k in _kids("Props"):
		var p := (k as Node3D).position
		inside = inside and _in_area(rect, p.x, p.z)
	_check(inside, "every prop stands inside the area's rect")
