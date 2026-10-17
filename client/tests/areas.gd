extends SceneTree
## Every converted area (client/areas/<id>.tscn, made by client/tools/build_area.gd from godot/data/slice/world.json) matches what today's runtime
## builder (godot/world/world_builder.gd) makes for that area. The areas are world.json's `order` without the instance (the Depths' floors are generated at
## runtime); each scene is checked on its own: instantiate, check, free. Every expected number is computed here from world.json the way world_builder.gd
## computes it (its own constants, DmModels.prop_parts, the hummock ring mesh), never read from a scene.
## Run: godot --headless --path client --script res://tests/areas.gd

const Build := preload("res://tools/build_area.gd")
const WORLD_JSON := "../godot/data/slice/world.json"
const TEX := "res://assets/slice/art/textures/%s.webp"
const COMMON := "res://areas/common/"
const EPS := 0.0005
## What world_builder hard-codes: the one hall with no gate, always open (`_gates`, `_apply_unlock_state`), and the area that draws each list
## that names none (`_water`, `_wing_floor`, `_hummocks`).
const ALWAYS_OPEN_DOOR := "chapter_graves"
const DRAWN_BY := {"water": "nave", "bog": "fen", "ponds": "acre", "wingFloor": "alchemist_wing", "hummocks": "fen"}
## world_builder._water: colour and opacity of the three kinds of water.
const WATER_LOOK := {"water": ["#15142a", 0.72, "water"], "bog": ["#0f2a2a", 0.82, "bog"], "ponds": ["#15142a", 0.72, "pond"]}

var _pass := 0
var _fail := 0
var _counts: Dictionary = {}      # area id (or "world") -> checks run
var _id := "world"                # what the running checks are about; failures name it
var _world: Dictionary
var _scene: Node3D
var _obstacles: Array = []
var _wall_colors: Dictionary = {}
var _uv2_cache: Dictionary = {}
var _seen: Dictionary = {}        # category -> how many of its things the scenes hold, against world.json in _test_totals
var _door_seen: Dictionary = {}   # door id -> scenes it is in
var _mm_files: Dictionary = {}    # scene file -> its MultiMesh table (_multimeshes_of_file)


func _check(ok: bool, what: String) -> void:
	_counts[_id] = int(_counts.get(_id, 0)) + 1
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL areas: ", _id, ": ", what)


func _initialize() -> void:
	_run.call_deferred()


func _finish() -> void:
	if _scene != null:
		root.remove_child(_scene)
		_scene.free()
	var rows: PackedStringArray = []
	for k: String in _counts:
		rows.append("%s %d" % [k, _counts[k]])
	print("INFO areas: checks per area: ", ", ".join(rows))
	if _fail > 0:
		printerr("FAIL areas: %d of %d checks failed" % [_fail, _pass + _fail])
	else:
		print("PASS areas (%d checks)" % _pass)
	quit(1 if _fail > 0 else 0)


func _near(a: float, b: float) -> bool:
	return absf(a - b) <= EPS


func _near_v(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) <= EPS


func _near_t(a: Transform3D, b: Transform3D) -> bool:
	return a.origin.distance_to(b.origin) <= EPS and a.basis.x.distance_to(b.basis.x) <= EPS and a.basis.y.distance_to(b.basis.y) <= EPS and a.basis.z.distance_to(b.basis.z) <= EPS


func _hex(v: Variant) -> Color:
	return Color.hex(int(v) * 256 + 255)


func _col_near(a: Color, b: Color, tol := 0.0001) -> bool:
	return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol and absf(a.a - b.a) <= tol


func _in_rect(rect: Dictionary, x: float, z: float) -> bool:
	return x >= rect.x0 and x <= rect.x1 and z >= rect.z0 and z <= rect.z1


## world_builder.area_at: the first area of `order` whose rect holds the point.
func _area_at(x: float, z: float) -> String:
	for id: String in _world.order:
		if _in_rect(_world.areas[id].rect, x, z):
			return id
	return ""


func _centre_area(r: Dictionary) -> String:
	return _area_at((float(r.x0) + float(r.x1)) / 2.0, (float(r.z0) + float(r.z1)) / 2.0)


func _kids(path: String) -> Array[Node]:
	var n := _scene.get_node_or_null(path)
	var out: Array[Node] = []
	if n != null:
		out.assign(n.get_children())
	return out


## Floats go through float32 first: a scene stores float32, so 0.7225 is 0.72250002 there and must round the same way here.
func _sig(parts: Array) -> String:
	var out := ""
	for p: Variant in parts:
		out += ("%.3f" % PackedFloat32Array([p])[0]) if (p is float) else str(p)
		out += "|"
	return out


func _sorted(list: Array[String]) -> Array[String]:
	list.sort()
	return list


func _see(category: String, n: int) -> void:
	_seen[category] = int(_seen.get(category, 0)) + n


func _run() -> void:
	var text := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://").path_join(WORLD_JSON))
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		printerr("FAIL areas: cannot read godot/data/slice/world.json")
		quit(1)
		return
	_world = parsed
	_wall_colors = _builder_wall_colors()
	_obstacles = _all_obstacles()
	var ids: Array[String] = []
	for id: String in _world.order:
		if not _world.areas[id].instance:
			ids.append(id)
	_id = "world"
	_test_world_first(ids)
	for id in ids:
		await _test_area(id)
	_id = "world"
	_test_totals(ids)
	_finish()


func _test_area(id: String) -> void:
	_id = id
	var path := "res://areas/%s.tscn" % id
	if not ResourceLoader.exists(path):
		_check(false, "%s is missing (run tools/rebuild/build-areas.sh %s)" % [path, id])
		return
	_scene = (load(path) as PackedScene).instantiate() as Node3D
	root.add_child(_scene)
	var a: Dictionary = _world.areas[id]
	_test_root(a)
	_test_floor(a)
	_test_walls()
	_test_props()
	_test_nodes()
	_test_decals()
	_test_water()
	_test_wing_floor()
	_test_hummocks()
	_test_lights()
	_test_colliders()
	_test_occluders()
	_test_lightmap(a, path)
	_test_bake_ready()
	_test_doors()
	await _test_navigation(a)
	_test_bounds(a)
	root.remove_child(_scene)
	_scene.free()
	_scene = null
	await process_frame


# ---------------------------------------------------------------- the world: files that belong to no one area
func _test_world_first(ids: Array[String]) -> void:
	# The scenes in client/areas are the converted areas: none missing, none left over.
	var have: Array[String] = []
	for f in DirAccess.get_files_at("res://areas"):
		if f.ends_with(".tscn"):
			have.append(f.get_basename())
	var want := ids.duplicate()
	_check(_sorted(have) == _sorted(want), "client/areas holds one scene per converted area (%d: %s); found %s" % [want.size(), ", ".join(want), ", ".join(have)])
	_check(ProjectSettings.get_setting("rendering/occlusion_culling/use_occlusion_culling", false) == true, "occlusion culling is on in the project")
	# world.json's `open` is what world_builder opens at start (_apply_unlock_state): a door is open when neither room has a seal and neither is an instance.
	var open_ok := true
	for d: Dictionary in _world.doors:
		var sealed := false
		for room: String in [d.a, d.b]:
			sealed = sealed or _world.areas[room].unlock != null or _world.areas[room].instance
		open_ok = open_ok and d.open == (not sealed)
	_check(open_ok and _world.doors.any(func(d: Dictionary) -> bool: return d.id == ALWAYS_OPEN_DOOR and d.open), "world.json's open doors are the ones world_builder opens at start, and %s is one" % ALWAYS_OPEN_DOOR)
	# Each list world_builder draws in a named area lies inside that area's rect, so the converter, which gives a rect to the area that holds its centre,
	# agrees with the builder, which names the area.
	for list_name: String in DRAWN_BY:
		var rect: Dictionary = _world.areas[DRAWN_BY[list_name]].rect
		var inside := true
		for r: Dictionary in _world[list_name]:
			if r.has("x0"):
				inside = inside and _centre_area(r) == DRAWN_BY[list_name]
			else:
				inside = inside and _in_rect(rect, r.x, r.z) and _area_at(r.x, r.z) == DRAWN_BY[list_name]
		_check(inside and not (_world[list_name] as Array).is_empty(), "every `%s` entry of world.json lies in the %s (%d entries)" % [list_name, DRAWN_BY[list_name], _world[list_name].size()])
	# The two decal textures every area uses are the ones world_builder paints at start-up.
	var builder := DmWorldBuilder.new()
	for pair in [["ring", builder._ring_texture()], ["glow", builder._glow_texture()]]:
		var want_img: Image = (pair[1] as ImageTexture).get_image()
		var file := Image.load_from_file(ProjectSettings.globalize_path(COMMON + pair[0] + ".png"))
		var ok := want_img != null and not want_img.is_empty() and file != null
		if ok:
			want_img.clear_mipmaps()
			file.convert(Image.FORMAT_RGBA8)
			ok = want_img.get_width() == file.get_width() and want_img.get_format() == file.get_format() and want_img.get_data() == file.get_data()
		_check(ok, "areas/common/%s.png equals world_builder's %s texture pixel for pixel" % [pair[0], pair[0]])
	builder.free()
	_test_compat_albedo()


## DmCompatAlbedo: every tinted texture the converter uses has an entry, and every entry is what measuring the texture's source image gives now (no stale table).
func _test_compat_albedo() -> void:
	var used := {}
	for k: String in _world.floors:
		var f: Dictionary = _world.floors[k]
		used[DmCompatAlbedo.key(String(f.tex), _hex(f.color))] = [String(f.tex), _hex(f.color)]
	for w: Dictionary in _world.walls:
		used[DmCompatAlbedo.key(String(w.texture), _hex(w.color))] = [String(w.texture), _hex(w.color)]
	used[DmCompatAlbedo.key("stone_wall", Color.html("#8a8296"))] = ["stone_wall", Color.html("#8a8296")]
	var missing: Array[String] = []
	for key: String in used:
		if not DmCompatAlbedo.TABLE.has(key):
			missing.append(key)
	_check(missing.is_empty(), "every tinted floor, wall and gate-post texture has a DmCompatAlbedo entry (missing: %s; `client/tools/compat_albedo.gd` prints them)" % str(missing))
	var stale: Array[String] = []
	for key: String in DmCompatAlbedo.TABLE:
		if not used.has(key):
			stale.append(key + " (unused)")
			continue
		var img := Image.load_from_file(ProjectSettings.globalize_path(TEX % String(used[key][0])))
		var got := DmCompatAlbedo.measure(img, used[key][1])
		var want: Vector3 = DmCompatAlbedo.TABLE[key]
		if absf(got.x - want.x) > 0.0006 or absf(got.y - want.y) > 0.0006 or absf(got.z - want.z) > 0.0006:
			stale.append("%s (table %s, measured %s)" % [key, want, got])
	_check(stale.is_empty(), "DmCompatAlbedo's table is what its textures measure, and holds nothing unused: %s" % str(stale))
	# Compatibility makes a tinted dark texture brighter than Forward+ does: the lift is above 1 for every floor and wall, and the lifted tint stays a colour.
	var lifts_ok := true
	for key: String in DmCompatAlbedo.TABLE:
		var r: Vector3 = DmCompatAlbedo.TABLE[key]
		lifts_ok = lifts_ok and r.x >= 1.0 and r.y >= 1.0 and r.z >= 1.0 and r.x < 2.0 and r.y < 2.0 and r.z < 2.0
	_check(lifts_ok, "every albedo lift is between 1 and 2")


## world_builder._walls: one material per texture for the whole world, made from the first wall that names it (areas in order of first appearance).
func _builder_wall_colors() -> Dictionary:
	var by_area: Dictionary = {}
	for w: Dictionary in _world.walls:
		if not by_area.has(w.area):
			by_area[w.area] = []
		by_area[w.area].append(w)
	var out: Dictionary = {}
	for id: String in by_area:
		for w: Dictionary in by_area[id]:
			if not out.has(w.texture):
				out[w.texture] = DmCompatAlbedo.tint(String(w.texture), _hex(w.color))
	return out


# ---------------------------------------------------------------- root
func _test_root(a: Dictionary) -> void:
	var r: Dictionary = a.rect
	_check(_scene.name == _id and _scene.get_meta("area_id", "") == _id, "root is the area '%s'" % _id)
	_check(_scene.get_meta("area_name", "") == a.name and _scene.get_meta("theme", "") == a.theme and _scene.get_meta("safe", null) == a.safe,
		"root carries the name '%s', the theme '%s' and safe = %s" % [a.name, a.theme, a.safe])
	var m: Array = _scene.get_meta("rect", [])
	_check(m.size() == 4 and _near(m[0], r.x0) and _near(m[1], r.z0) and _near(m[2], r.x1) and _near(m[3], r.z1), "root carries the rect")
	for g in ["Floor", "Walls", "Props", "GatherNodes", "Decals", "Water", "Doors", "Lights", "Occluders", "Colliders", "Navigation", "Lightmap"]:
		_check(_scene.has_node(g), "group %s exists" % g)


# ---------------------------------------------------------------- floors
## One ground quad against world_builder._plane / _floor_mat: the rect, the height, the theme's look, UVs anchored to the world, a lightmap UV2.
func _floor_quad(mi: MeshInstance3D, x0: float, z0: float, x1: float, z1: float, theme: String, y: float) -> Dictionary:
	var f: Dictionary = _world.floors[theme]
	var out := {"covers its rect": false, "sits at its height": false, "has its theme's look": false, "has world-anchored UVs": false, "has a lightmap UV2": false, "is static for baked lighting": false}
	if mi == null or mi.mesh == null:
		return out
	var box := mi.mesh.get_aabb()
	out["covers its rect"] = _near(mi.position.x + box.position.x, x0) and _near(mi.position.x + box.end.x, x1) and _near(mi.position.z + box.position.z, z0) and _near(mi.position.z + box.end.z, z1)
	out["sits at its height"] = _near(mi.position.y, y) and _near(box.size.y, 0.0)
	var m := mi.material_override as StandardMaterial3D
	var look := m != null and m.albedo_texture != null and m.albedo_texture.resource_path == TEX % f.tex and m.albedo_color.is_equal_approx(DmCompatAlbedo.tint(String(f.tex), _hex(f.color)))
	look = look and m != null and _near(m.roughness, float(f.rough)) and m.texture_filter == DmWorldBuilder.SHARP and m.uv1_scale.is_equal_approx(Vector3.ONE)
	if f.has("glow"):
		look = look and m.emission_enabled and m.emission.is_equal_approx(_hex(f.glow)) and m.emission_texture != null and m.emission_texture.resource_path == TEX % f.tex \
			and m.emission_operator == BaseMaterial3D.EMISSION_OP_MULTIPLY
	elif m != null:
		look = look and not m.emission_enabled
	out["has its theme's look"] = look
	var arrays := mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv_ok := verts.size() >= 4 and uvs.size() == verts.size() and norms.size() == verts.size()
	var t := float(f.tile)
	for i in verts.size():
		if uv_ok:
			uv_ok = _near(uvs[i].x, (verts[i].x + mi.position.x) / t) and _near(uvs[i].y, (verts[i].z + mi.position.z) / t) and norms[i].distance_to(Vector3.UP) < 0.001
	out["has world-anchored UVs"] = uv_ok
	out["has a lightmap UV2"] = (arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array).size() == verts.size()
	out["is static for baked lighting"] = mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC
	return out


func _merge_into(acc: Dictionary, one: Dictionary) -> void:
	for k: String in one:
		acc[k] = acc.get(k, true) and one[k]


func _check_each(label: String, results: Dictionary) -> void:
	for k: String in results:
		_check(results[k], "%s: %s" % [label, k])


func _test_floor(a: Dictionary) -> void:
	var r: Dictionary = a.rect
	_check_each("the ground", _floor_quad(_scene.get_node_or_null("Floor/ground") as MeshInstance3D, r.x0 - 0.8, r.z0 - 0.8, r.x1 + 0.8, r.z1 + 0.8, a.theme, 0.0))
	# world_builder draws every path in the nave's flagstone at y 0.008; an area holds the paths whose centre lies in it.
	var expect: Array[String] = []
	var acc: Dictionary = {}
	var by_rect: Dictionary = {}
	for p: Dictionary in _world.paths:
		if _centre_area(p) == _id:
			expect.append(_sig([p.x0, p.z0, p.x1, p.z1]))
			by_rect[_sig([p.x0, p.z0, p.x1, p.z1])] = p
	var got: Array[String] = []
	for k in _kids("Floor"):
		if String(k.name).begins_with("path_"):
			var mi := k as MeshInstance3D
			var b := mi.mesh.get_aabb()
			var key := _sig([mi.position.x + b.position.x, mi.position.z + b.position.z, mi.position.x + b.end.x, mi.position.z + b.end.z])
			got.append(key)
			if by_rect.has(key):
				var p: Dictionary = by_rect[key]
				_merge_into(acc, _floor_quad(mi, p.x0, p.z0, p.x1, p.z1, "nave", 0.008))
	_check(_sorted(expect) == _sorted(got), "%d path floors cover the same rects as world.json" % expect.size())
	if not expect.is_empty():
		_check_each("the path floors", acc)
	_see("paths", got.size())


# ---------------------------------------------------------------- walls
func _nbox(b: Dictionary) -> Dictionary:
	return {"x0": minf(b.x0, b.x1), "x1": maxf(b.x0, b.x1), "z0": minf(b.z0, b.z1), "z1": maxf(b.z0, b.z1)}


func _test_walls() -> void:
	var expect: Array[String] = []
	for w: Dictionary in _world.walls:
		if w.area == _id:
			var b := _nbox(w.box)
			var c: Color = _wall_colors[w.texture]
			expect.append(_sig([(b.x0 + b.x1) / 2.0, w.height / 2.0, (b.z0 + b.z1) / 2.0, b.x1 - b.x0, w.height, b.z1 - b.z0, w.texture, c.r, c.g, c.b]))
	var got: Array[String] = []
	var mat_ok := true
	var uv2_ok := true
	var static_ok := true
	for k in _kids("Walls"):
		var mi := k as MeshInstance3D
		var bm := mi.mesh as BoxMesh
		var m := mi.material_override as StandardMaterial3D
		var tex := ""
		var c := Color.BLACK
		if m != null and m.albedo_texture != null:
			tex = m.albedo_texture.resource_path.get_file().get_basename()
			c = m.albedo_color
			mat_ok = mat_ok and m.albedo_texture.resource_path == TEX % tex and m.uv1_triplanar and m.uv1_world_triplanar and m.uv1_scale.is_equal_approx(Vector3.ONE / 4.0) \
				and _near(m.roughness, 0.92) and m.texture_filter == DmWorldBuilder.SHARP
		else:
			mat_ok = false
		got.append(_sig([mi.position.x, mi.position.y, mi.position.z, bm.size.x, bm.size.y, bm.size.z, tex, c.r, c.g, c.b]))
		uv2_ok = uv2_ok and bm.add_uv2
		static_ok = static_ok and mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC
	_check(_sorted(expect) == _sorted(got), "%d wall boxes match world.json (position, size, texture and tint as world_builder shares them)" % expect.size())
	_check(mat_ok, "walls use the triplanar world-anchored texture material (roughness 0.92, quarter-scale UVs)")
	_check(uv2_ok and static_ok, "walls are static with generated lightmap UV2")
	_see("walls", got.size())


# ---------------------------------------------------------------- props
func _placement(p: Dictionary) -> Transform3D:
	var tilt: float = p.tilt
	return Transform3D(Basis.from_euler(Vector3(tilt, p.rot, tilt * 0.6), EULER_ORDER_XYZ) * Basis.from_scale(Vector3.ONE * float(p.scale)), Vector3(p.x, p.y, p.z))


func _meshes_of(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in n.find_children("*", "MeshInstance3D", true, false):
		if (c as MeshInstance3D).mesh != null:
			out.append(c)
	return out


func _has_uv2(mesh: Mesh) -> bool:
	var key := mesh.get_instance_id()
	if not _uv2_cache.has(key):
		_uv2_cache[key] = mesh.get_surface_count() > 0 and (mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2] as PackedVector2Array).size() > 0
	return _uv2_cache[key]


## The bake takes every mesh that is static for baked lighting: each needs a lightmap UV2, or the bake fails on it.
func _test_bake_ready() -> void:
	var missing: Array = []
	var n := 0
	for c in _scene.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null or mi.gi_mode != GeometryInstance3D.GI_MODE_STATIC:
			continue
		n += 1
		if not _has_uv2(mi.mesh):
			missing.append(String(_scene.get_path_to(mi)))
	_check(n > 0 and missing.is_empty(), "every one of the %d meshes static for the bake carries a lightmap UV2 (not: %s)" % [n, str(missing.slice(0, 4))])


func _test_props() -> void:
	var list: Array = []
	var by_kind: Dictionary = {}
	for p: Dictionary in _world.props:
		if p.area == _id:
			list.append(p)
			if _world.propSpecs[p.prop].url != null:
				by_kind[p.prop] = int(by_kind.get(p.prop, 0)) + 1
	var got_kind: Dictionary = {}
	for k in _kids("Props"):
		var kind := String(k.get_meta("prop_kind", ""))
		got_kind[kind] = int(got_kind.get(kind, 0)) + 1
	_check(got_kind == by_kind, "prop count per kind matches world.json (%d kinds, %d props with a model)" % [by_kind.size(), _sum(by_kind)])
	var idx: Dictionary = {}
	var place_ok := true
	var prefab_ok := true
	var mesh_ok := true
	var range_ok := true
	var static_ok := true
	var uv2_ok := true
	var small_n := 0
	var meshes_n := 0
	for p: Dictionary in list:
		var kind: String = p.prop
		var i: int = idx.get(kind, 0)
		idx[kind] = i + 1
		var spec: Dictionary = _world.propSpecs[kind]
		if spec.url == null:
			continue
		var node := _scene.get_node_or_null("Props/%s_%03d" % [kind, i]) as Node3D
		if node == null:
			place_ok = false
			printerr("  missing prop node ", kind, i)
			continue
		var want := _placement(p)
		place_ok = place_ok and _near_t(node.transform, want)
		prefab_ok = prefab_ok and node.scene_file_path.begins_with("res://areas/props/")
		# world_builder._prop_batch: DmModels.prop_parts, each part under the placement.
		var parts: Array = DmModels.prop_parts(spec.url, float(spec.height))
		var meshes := _meshes_of(node)
		mesh_ok = mesh_ok and meshes.size() == parts.size()
		var small: bool = float(spec.height) <= Build.SMALL_PROP_MAX_HEIGHT
		if small:
			small_n += 1
		for j in mini(meshes.size(), parts.size()):
			var mi := meshes[j]
			mesh_ok = mesh_ok and mi.mesh == parts[j].mesh and _near_t(mi.global_transform, want * (parts[j].local as Transform3D))
			meshes_n += 1
			static_ok = static_ok and mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC
			uv2_ok = uv2_ok and _has_uv2(mi.mesh)
			# world_builder: only props taller than 1.5 m cast the moon's shadow; the converter adds the visibility range to the others.
			if small:
				range_ok = range_ok and _near(mi.visibility_range_end, Build.SMALL_PROP_VISIBLE_END) and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			else:
				range_ok = range_ok and mi.visibility_range_end == 0.0 and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_check(place_ok, "every prop is placed with world_builder's transform (position, yaw, tilt, scale)")
	_check(prefab_ok, "props are instances of the per-model prefabs in areas/props")
	_check(mesh_ok, "%d prop meshes are DmModels.prop_parts' meshes, where world_builder puts them (placement x normalisation x the part's own transform)" % meshes_n)
	_check(range_ok, "%d props up to %s m have a visibility range and no shadow, the %d taller ones none and a shadow" % [small_n, Build.SMALL_PROP_MAX_HEIGHT, _with_model(list) - small_n])
	_check(static_ok and uv2_ok, "prop meshes are static for baked lighting and carry lightmap UV2")
	_see("props", _sum(got_kind))


func _with_model(list: Array) -> int:
	var n := 0
	for p: Dictionary in list:
		if _world.propSpecs[p.prop].url != null:
			n += 1
	return n


func _sum(d: Dictionary) -> int:
	var n := 0
	for k: Variant in d:
		n += int(d[k])
	return n


# ---------------------------------------------------------------- gathering nodes
func _test_nodes() -> void:
	var list: Array = []
	for n: Dictionary in _world.nodes:
		if n.area == _id:
			list.append(n)
	var holder_ok := true
	var model_ok := true
	var ore_ok := true
	var standin_ok := true
	for n: Dictionary in list:
		var holder := _scene.get_node_or_null("GatherNodes/%s" % n.id) as Node3D
		if holder == null:
			holder_ok = false
			continue
		holder_ok = holder_ok and _near_v(holder.position, Vector3(n.x, 0.04, n.z)) and holder.basis.is_equal_approx(Basis(Vector3.UP, float(n.rot)))
		holder_ok = holder_ok and holder.get_meta("node_id", "") == n.id and holder.get_meta("node_kind", "") == n.kind
		var extra := 0
		if n.model != null:
			var model := holder.get_node_or_null("model") as Node3D
			if model == null:
				model_ok = false
				continue
			extra = 1
			model_ok = model_ok and model.scene_file_path.begins_with("res://areas/props/")
			var parts: Array = DmModels.prop_parts(n.model, float(n.modelHeight))
			var meshes := _meshes_of(model)
			model_ok = model_ok and meshes.size() == parts.size()
			for j in mini(meshes.size(), parts.size()):
				model_ok = model_ok and meshes[j].mesh == parts[j].mesh and _near_t(meshes[j].global_transform, holder.global_transform * (parts[j].local as Transform3D))
			if n.kind == "seam" or n.kind == "geode":
				extra += 3
				ore_ok = ore_ok and _ore_ok(holder, n)
		else:
			extra = _standin(holder, n)
			standin_ok = standin_ok and extra >= 0
		holder_ok = holder_ok and holder.get_child_count() == maxi(extra, 0)
	_check(holder_ok and _kids("GatherNodes").size() == list.size(), "%d gathering nodes stand where world.json puts them (position, yaw, id, kind) and hold what world_builder builds" % list.size())
	_check(model_ok, "gathering-node models are DmModels.prop_parts' meshes under the node")
	_check(ore_ok, "seams and geodes carry world_builder's three emissive crystals in their tint")
	_check(standin_ok, "nodes without a model get their stand-in (herb stem and cap, pool ring, tree trunk)")
	_see("nodes", list.size())


func _ore_ok(holder: Node3D, n: Dictionary) -> bool:
	var tint := Color.html(n.tint)
	var k := 0
	var ok := true
	for sh in [[0.2, 0.5, 0.45], [-0.25, 0.45, 0.42], [0.45, 0.35, 0.3]]:
		var vi := holder.get_node_or_null("crystal_%d" % k) as MeshInstance3D
		k += 1
		if vi == null:
			return false
		var bm := vi.mesh as BoxMesh
		var m := vi.material_override as StandardMaterial3D
		ok = ok and bm != null and bm.size.is_equal_approx(Vector3(0.12, 0.34, 0.12)) and m != null and m.albedo_color.is_equal_approx(tint) and m.emission_enabled \
			and m.emission.is_equal_approx(tint) and _near(m.emission_energy_multiplier, 0.9 if n.kind == "geode" else 0.55)
		ok = ok and _near_v(vi.position, Vector3(sh[0], sh[1] * 0.6, sh[2] * 0.4)) and vi.basis.is_equal_approx(Basis.from_euler(Vector3(0.3, sh[0] * 3.0, sh[0]), EULER_ORDER_YXZ))
	return ok


## world_builder._node_standin: returns how many children the node should hold, or -1 when one is wrong.
func _standin(holder: Node3D, n: Dictionary) -> int:
	var tint := Color.html(n.tint)
	if n.kind == "herb":
		var stem := holder.get_node_or_null("stem") as MeshInstance3D
		var cap := holder.get_node_or_null("cap") as MeshInstance3D
		if stem == null or cap == null:
			return -1
		var cm := stem.mesh as CylinderMesh
		var sm := cap.mesh as SphereMesh
		var sm_m := stem.material_override as StandardMaterial3D
		var cap_m := cap.material_override as StandardMaterial3D
		var ok := cm != null and _near(cm.top_radius, 0.03) and _near(cm.bottom_radius, 0.06) and _near(cm.height, 0.4) and cm.radial_segments == 5 and _near_v(stem.position, Vector3(0, 0.2, 0))
		ok = ok and sm_m != null and sm_m.albedo_color.is_equal_approx(Color(0.21, 0.28, 0.16)) and _near(sm_m.roughness, 0.9)
		ok = ok and sm != null and _near(sm.radius, 0.16) and _near(sm.height, 0.26) and sm.radial_segments == 8 and sm.rings == 4 and _near_v(cap.position, Vector3(0, 0.45, 0))
		ok = ok and cap_m != null and cap_m.albedo_color.is_equal_approx(tint) and cap_m.emission_enabled and cap_m.emission.is_equal_approx(tint) and _near(cap_m.emission_energy_multiplier, 0.7)
		return 2 if ok else -1
	if n.kind == "pool":
		var ring := holder.get_node_or_null("ring") as MeshInstance3D
		if ring == null:
			return -1
		var qm := ring.mesh as QuadMesh
		var m := ring.material_override as StandardMaterial3D
		var ok2 := qm != null and qm.size.is_equal_approx(Vector2(1.6, 1.6)) and qm.orientation == PlaneMesh.FACE_Y and _near_v(ring.position, Vector3(0, 0.09, 0))
		ok2 = ok2 and ring.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and m != null and m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED \
			and m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and m.albedo_texture != null and m.albedo_texture.resource_path == COMMON + "ring.png" \
			and m.texture_filter == DmWorldBuilder.SHARP and m.albedo_color.is_equal_approx(Color(tint.r * 2.0, tint.g * 2.0, tint.b * 2.0, 0.28))
		return 1 if ok2 else -1
	if n.kind == "tree":
		var tm := holder.get_node_or_null("trunk") as MeshInstance3D
		if tm == null:
			return -1
		var cm2 := tm.mesh as CylinderMesh
		var m2 := tm.material_override as StandardMaterial3D
		var ok3 := cm2 != null and _near(cm2.top_radius, 0.2) and _near(cm2.bottom_radius, 0.35) and _near(cm2.height, 2.4) and cm2.radial_segments == 7 and _near_v(tm.position, Vector3(0, 1.2, 0))
		ok3 = ok3 and m2 != null and m2.albedo_color.is_equal_approx(Color(0.24, 0.18, 0.14))
		return 1 if ok3 else -1
	return 0   # world_builder draws nothing for any other kind without a model


# ---------------------------------------------------------------- decals and puddles
func _flat_ok(mi: MeshInstance3D) -> bool:
	var qm := mi.mesh as QuadMesh
	return qm != null and qm.orientation == PlaneMesh.FACE_Y and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _mat_sig(m: StandardMaterial3D) -> Array:
	if m == null:
		return ["none"]
	var tex := m.albedo_texture.resource_path if m.albedo_texture != null else "-"
	return [tex, m.albedo_color.r, m.albedo_color.g, m.albedo_color.b, m.albedo_color.a, m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, m.transparency]


func _test_decals() -> void:
	var expect: Array[String] = []
	var kinds: Dictionary = {}
	var puddles: Array[String] = []
	for d: Dictionary in _world.decals:
		if d.area != _id:
			continue
		var col := Color.html(d.color)
		var sigil: bool = d.kind == "sigil"
		var c := Color(col, float(d.opacity)) if sigil else Color(col.r * 0.6, col.g * 0.6, col.b * 0.6, float(d.opacity) * 0.8)
		var tex := COMMON + ("ring.png" if sigil else "glow.png")
		expect.append(_sig([d.kind, d.x, 0.03 if sigil else 0.02, d.z, d.r * 2.0, sin(d.rot), cos(d.rot)] + _mat_sig_of(tex, c)))
		kinds[d.kind] = int(kinds.get(d.kind, 0)) + 1
	for p: Dictionary in _world.puddles:
		if p.area == _id:
			puddles.append(_sig([p.x, 0.025, p.z, p.r * 2.0 * float(p.sx), p.r * 2.0, sin(p.rot), cos(p.rot)] + _mat_sig_of(COMMON + "glow.png", Color(0.06, 0.07, 0.14, 0.75))))
	var got: Array[String] = []
	var got_p: Array[String] = []
	var flat_ok := true
	var filter_ok := true
	for k in _kids("Decals"):
		var mi := k as MeshInstance3D
		var qm := mi.mesh as QuadMesh
		flat_ok = flat_ok and _flat_ok(mi) and mi.gi_mode == GeometryInstance3D.GI_MODE_DISABLED
		var m := mi.material_override as StandardMaterial3D
		if String(k.name).begins_with("puddle_"):
			got_p.append(_sig([mi.position.x, mi.position.y, mi.position.z, qm.size.x, qm.size.y, sin(mi.rotation.y), cos(mi.rotation.y)] + _mat_sig(m)))
		else:
			filter_ok = filter_ok and m != null and m.texture_filter == DmWorldBuilder.SHARP
			got.append(_sig([String(k.name).rsplit("_", true, 1)[0], mi.position.x, mi.position.y, mi.position.z, qm.size.x, sin(mi.rotation.y), cos(mi.rotation.y)] + _mat_sig(m)))
	var summary: PackedStringArray = []
	for kd: String in kinds:
		summary.append("%d %s" % [kinds[kd], kd])
	_check(_sorted(expect) == _sorted(got), "%d decals (%s) match world.json (kind, place, size, yaw, texture, colour, opacity)" % [expect.size(), ", ".join(summary)])
	_check(_sorted(puddles) == _sorted(got_p), "%d puddles match world.json (place, size, yaw, look)" % puddles.size())
	_check(flat_ok and filter_ok, "decals and puddles are flat unshaded quads that cast no shadow and take no light bake")
	_see("decals", got.size())
	_see("puddles", got_p.size())


func _mat_sig_of(tex: String, c: Color) -> Array:
	return [tex, c.r, c.g, c.b, c.a, true, BaseMaterial3D.TRANSPARENCY_ALPHA]


# ---------------------------------------------------------------- water, bog and ponds
func _test_water() -> void:
	var expect: Array[String] = []
	for list_name: String in WATER_LOOK:
		if DRAWN_BY[list_name] != _id:
			continue
		var look: Array = WATER_LOOK[list_name]
		var col := Color.html(look[0])
		for r: Dictionary in _world[list_name]:
			expect.append(_sig([look[2], (r.x0 + r.x1) / 2.0, 0.06, (r.z0 + r.z1) / 2.0, r.x1 - r.x0, r.z1 - r.z0, col.r, col.g, col.b, look[1]]))
	var got: Array[String] = []
	var look_ok := true
	for k in _kids("Water"):
		var mi := k as MeshInstance3D
		var pm := mi.mesh as PlaneMesh
		var m := mi.material_override as StandardMaterial3D
		look_ok = look_ok and pm != null and pm.orientation == PlaneMesh.FACE_Y and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and m != null \
			and m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and _near(m.roughness, 0.16) and _near(m.metallic, 0.1) and m.albedo_texture == null
		if pm != null and m != null:
			got.append(_sig([String(k.name).rsplit("_", true, 1)[0], mi.position.x, mi.position.y, mi.position.z, pm.size.x, pm.size.y, m.albedo_color.r, m.albedo_color.g, m.albedo_color.b, m.albedo_color.a]))
	_check(_sorted(expect) == _sorted(got), "%d water planes match world.json (the area that draws water, bog or ponds: place, size, colour, opacity)" % expect.size())
	_check(look_ok, "water planes are glossy alpha planes that cast no shadow")
	_see("water planes", got.size())


# ---------------------------------------------------------------- the alchemist wing's rugs and stains
func _test_wing_floor() -> void:
	var expect: Array[String] = []
	var rugs := 0
	if DRAWN_BY.wingFloor == _id:
		for f: Dictionary in _world.wingFloor:
			var col := Color.html(f.color)
			var rug: bool = f.kind == "rug"
			var c := col * 0.45 if rug else Color(col, 0.8)
			expect.append(_sig([f.kind, f.x, 0.012 if rug else 0.014, f.z, f.w, f.d, sin(f.rot), cos(f.rot), c.r, c.g, c.b, rug, "-" if rug else COMMON + "glow.png"]))
			if rug:
				rugs += 1
			if rug and f.alt != null:
				var t := col * 0.8
				expect.append(_sig(["trim", f.x, 0.016, f.z, f.w - 0.5, f.d - 0.5, sin(f.rot), cos(f.rot), t.r, t.g, t.b, true, "-"]))
	var got: Array[String] = []
	var look_ok := true
	var n := 0
	for k in _kids("Floor"):
		var nm := String(k.name)
		if not (nm.begins_with("rug_") or nm.begins_with("stain_")):
			continue
		n += 1
		var mi := k as MeshInstance3D
		var qm := mi.mesh as QuadMesh
		var m := mi.material_override as StandardMaterial3D
		var rug := nm.begins_with("rug_")
		var trim := nm.ends_with("_trim")
		look_ok = look_ok and _flat_ok(mi) and m != null and _near(m.roughness, 1.0) and (m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA) == (not rug)
		look_ok = look_ok and mi.gi_mode == (GeometryInstance3D.GI_MODE_STATIC if rug else GeometryInstance3D.GI_MODE_DISABLED)
		got.append(_sig(["trim" if trim else nm.split("_")[0], mi.position.x, mi.position.y, mi.position.z, qm.size.x, qm.size.y, sin(mi.rotation.y), cos(mi.rotation.y),
			m.albedo_color.r, m.albedo_color.g, m.albedo_color.b, rug, m.albedo_texture.resource_path if m.albedo_texture != null else "-"]))
	_check(_sorted(expect) == _sorted(got), "%d wing floor quads (%d rugs with their trims, the stains) match world.json (place, size, yaw, colour)" % [expect.size(), rugs])
	_check(look_ok, "rugs are matt, static quads; stains are alpha quads with the glow texture; none casts a shadow")
	_see("wing floor quads", got.size())


# ---------------------------------------------------------------- the fen's hummocks
func _test_hummocks() -> void:
	var mm_node := _scene.get_node_or_null("Floor/hummocks") as MultiMeshInstance3D
	var rim_node := _scene.get_node_or_null("Floor/hummock_rims") as MultiMeshInstance3D
	if DRAWN_BY.hummocks != _id:
		_check(mm_node == null and rim_node == null, "no hummocks outside the fen")
		return
	var hum: Array = _world.hummocks
	_check(mm_node != null and rim_node != null and mm_node.multimesh.instance_count == hum.size() and rim_node.multimesh.instance_count == hum.size(), "%d hummocks, each a mound and a rim ring" % hum.size())
	if mm_node == null or rim_node == null:
		return
	var mound: Array[Transform3D] = []
	var rim: Array[Transform3D] = []
	for h: Dictionary in hum:
		var sc := Basis.from_scale(Vector3(h.r, 1.0, h.r))
		mound.append(Transform3D(sc, Vector3(h.x, 0.17, h.z)))
		rim.append(Transform3D(sc, Vector3(h.x, 0.0, h.z)))
	var why_mounds := _instances_in_file(mm_node, mound)
	var why_rims := _instances_in_file(rim_node, rim)
	_check(why_mounds == "" and why_rims == "",
		"every hummock stands at world_builder's place and radius (mound at 0.17, rim at the ground) in the scene file: mounds %s; rims %s" % [why_mounds, why_rims])
	var cm := mm_node.multimesh.mesh as CylinderMesh
	var mat := mm_node.material_override as StandardMaterial3D
	_check(cm != null and _near(cm.top_radius, 0.9) and _near(cm.bottom_radius, 1.0) and _near(cm.height, 0.34) and cm.radial_segments == 18, "the mound is world_builder's 18-sided cylinder (0.9 to 1.0 m, 0.34 m high)")
	_check(mat != null and mat.albedo_color.is_equal_approx(Color.html("#46574a") * 0.45) and _near(mat.roughness, 1.0) and mat.emission_enabled and mat.emission.is_equal_approx(Color.html("#0a2622"))
		and _near(mat.emission_energy_multiplier, 0.3), "the mound is the muted peat green with its faint teal glow")
	var want_ring := DmWorldBuilder._hummock_ring_mesh()
	var got_ring := rim_node.multimesh.mesh as ArrayMesh
	var wa := want_ring.surface_get_arrays(0)
	var ga := got_ring.surface_get_arrays(0) if got_ring != null and got_ring.get_surface_count() == 1 else []
	var ring_ok: bool = not ga.is_empty() and wa[Mesh.ARRAY_INDEX] == ga[Mesh.ARRAY_INDEX] and (wa[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == (ga[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	if ring_ok:
		for i in (wa[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
			ring_ok = ring_ok and (wa[Mesh.ARRAY_VERTEX] as PackedVector3Array)[i].distance_to((ga[Mesh.ARRAY_VERTEX] as PackedVector3Array)[i]) < 0.00001
	_check(ring_ok, "the rim is world_builder's flat ring mesh (vertices and indices)")
	var rm := rim_node.material_override as StandardMaterial3D
	_check(rm != null and rm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED and rm.albedo_color.is_equal_approx(Color(0.435, 0.839, 0.769, 0.38)) and rm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA
		and rm.blend_mode == BaseMaterial3D.BLEND_MODE_ADD and rm.cull_mode == BaseMaterial3D.CULL_DISABLED and rim_node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"the rim is a pale teal, additive, unshaded ring that casts no shadow")
	_see("hummocks", hum.size())


# ---------------------------------------------------------------- MultiMesh data in the scene file
## A headless Godot (the dummy renderer) neither keeps nor returns the transforms set with set_instance_transform, so what a scene will draw is read from its
## file: the `buffer` of the MultiMesh sub-resource behind each MultiMeshInstance3D, by node path. {path: {"count": int, "buffer": PackedFloat32Array or null}}
func _multimeshes_of_file(scene_path: String) -> Dictionary:
	if _mm_files.has(scene_path):
		return _mm_files[scene_path]
	var subs: Dictionary = {}     # sub-resource id -> {count, buffer}
	var nodes: Dictionary = {}    # node path -> sub-resource id
	var cur_sub := ""
	var cur_node := ""
	for line in FileAccess.get_file_as_string(scene_path).split("\n"):
		if line.begins_with("["):
			cur_sub = ""
			cur_node = ""
			if line.begins_with("[sub_resource type=\"MultiMesh\""):
				cur_sub = line.get_slice("id=\"", 1).get_slice("\"", 0)
				subs[cur_sub] = {"count": 0, "buffer": null}
			elif line.begins_with("[node ") and line.contains("type=\"MultiMeshInstance3D\""):
				var nm := line.get_slice("name=\"", 1).get_slice("\"", 0)
				var parent := line.get_slice("parent=\"", 1).get_slice("\"", 0) if line.contains("parent=\"") else ""
				cur_node = nm if parent == "." or parent == "" else parent + "/" + nm
		elif cur_sub != "" and line.begins_with("instance_count = "):
			subs[cur_sub].count = int(line.get_slice(" = ", 1))
		elif cur_sub != "" and line.begins_with("buffer = PackedFloat32Array("):
			var body := line.get_slice("(", 1).trim_suffix(")")
			var floats := PackedFloat32Array()
			for v in body.split(","):
				floats.append(v.strip_edges().to_float())
			subs[cur_sub].buffer = floats
		elif cur_node != "" and line.begins_with("multimesh = SubResource("):
			nodes[cur_node] = line.get_slice("\"", 1)
	var out: Dictionary = {}
	for path: String in nodes:
		out[path] = subs.get(nodes[path], {"count": 0, "buffer": null})
	_mm_files[scene_path] = out
	return out


## "" when the scene file holds exactly these transforms for the MultiMeshInstance3D (12 floats each: the basis rows with the origin), else why not.
func _instances_in_file(mmi: MultiMeshInstance3D, want: Array[Transform3D]) -> String:
	var table := _multimeshes_of_file(_scene.scene_file_path)
	var path := String(_scene.get_path_to(mmi))
	if not table.has(path):
		return "%s is not in the file" % path
	var entry: Dictionary = table[path]
	if entry.count != want.size():
		return "%s holds %d instances, not %d" % [path, entry.count, want.size()]
	if entry.buffer == null:
		return "%s has %d instances and no transform data in the file" % [path, want.size()]
	var buf: PackedFloat32Array = entry.buffer
	if buf.size() != want.size() * 12:
		return "%s has %d floats, not %d" % [path, buf.size(), want.size() * 12]
	for i in want.size():
		var t := want[i]
		var row := [t.basis.x.x, t.basis.y.x, t.basis.z.x, t.origin.x, t.basis.x.y, t.basis.y.y, t.basis.z.y, t.origin.y, t.basis.x.z, t.basis.y.z, t.basis.z.z, t.origin.z]
		for j in 12:
			if absf(buf[i * 12 + j] - row[j]) > 0.0005:
				return "%s instance %d differs (float %d is %s, not %s)" % [path, i, j, buf[i * 12 + j], row[j]]
	return ""


# ---------------------------------------------------------------- lights
func _pool_quads() -> Array:
	var tone := {"gain": 1.0, "scale": 1.0}
	if _id == "nave":
		tone = {"gain": 0.68, "scale": 0.8}
	var out: Array = []
	for p: Dictionary in _world.props:
		if p.area != _id:
			continue
		var spec: Dictionary = _world.propSpecs[p.prop]
		if spec.has("light") and spec.light != null:
			var L: Dictionary = spec.light
			var c := _hex(L.pool if L.has("pool") and L.pool != null else 0xc9864a) * (0.32 * float(tone.gain))
			c.a = 1.0
			out.append({"x": p.x, "z": p.z, "r": float(L.distance) * 0.42 * float(tone.scale), "c": c})
	return out


func _test_lights() -> void:
	var expect: Array[String] = []
	var lights := 0
	for p: Dictionary in _world.props:
		if p.area != _id:
			continue
		var spec: Dictionary = _world.propSpecs[p.prop]
		if spec.has("light") and spec.light != null:
			var L: Dictionary = spec.light
			var c := _hex(L.color)
			expect.append(_sig([p.x, float(L.y) * float(p.scale) + float(p.y), p.z, float(L.distance), float(L.intensity) * DmWorldBuilder.POINT_K, c.r, c.g, c.b]))
			lights += 1
	var got: Array[String] = []
	var bake_ok := true
	var flame_ok := true
	var pool_meshes := 0
	for k in _kids("Lights"):
		if k is OmniLight3D:
			var l := k as OmniLight3D
			got.append(_sig([l.position.x, l.position.y, l.position.z, l.omni_range, l.light_energy, l.light_color.r, l.light_color.g, l.light_color.b]))
			bake_ok = bake_ok and l.light_bake_mode == Light3D.BAKE_STATIC and _near(l.omni_attenuation, 1.3)
			# The flame (world_builder._prop_light): a small unshaded glow at the light.
			var fi := l.get_node_or_null("flame") as MeshInstance3D
			var sm: SphereMesh = fi.mesh as SphereMesh if fi != null else null
			var fm: StandardMaterial3D = fi.material_override as StandardMaterial3D if fi != null else null
			flame_ok = flame_ok and sm != null and _near(sm.radius, 0.1) and _near(sm.height, 0.2) and sm.radial_segments == 8 and sm.rings == 4 and fi.position.is_zero_approx() \
				and fm != null and fm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED and fm.albedo_color.is_equal_approx(l.light_color.lightened(0.3)) \
				and fi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif String(k.name) == "light_pools":
			pool_meshes += 1
	_check(_sorted(expect) == _sorted(got), "%d prop lights match world.json (place, range, energy, colour)" % lights)
	_check(bake_ok, "prop lights are static-bake placeholders with world_builder's attenuation")
	_check(flame_ok, "each light carries world_builder's flame sphere (0.1 m radius, unshaded, the light's colour lightened)")
	_check(_kids("Lights").size() == lights + pool_meshes and pool_meshes == (1 if lights > 0 else 0), "%d lights and %s light-pool mesh, nothing else" % [lights, "one" if lights > 0 else "no"])
	_see("lights", lights)
	if lights == 0:
		return
	# The pool mesh (world_builder._light_pools): one quad per flame, radius 0.42 x range (the nave: 0.8 x that, 0.68 x as bright), tinted by the light's pool colour.
	var pm := _scene.get_node("Lights/light_pools") as MeshInstance3D
	var arrays := pm.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var want := _pool_quads()
	var quads_ok := verts.size() == want.size() * 6 and cols.size() == verts.size()
	var want_by_key: Dictionary = {}
	for q: Dictionary in want:
		want_by_key[_sig([q.x - q.r, q.z - q.r, q.x + q.r, q.z + q.r])] = q.c
	if quads_ok:
		for i in want.size():
			var lo := Vector3(INF, 0, INF)
			var hi := Vector3(-INF, 0, -INF)
			var flat := true
			for j in 6:
				var v := verts[i * 6 + j]
				lo = Vector3(minf(lo.x, v.x), 0, minf(lo.z, v.z))
				hi = Vector3(maxf(hi.x, v.x), 0, maxf(hi.z, v.z))
				flat = flat and _near(v.y, 0.015)
			var key := _sig([lo.x, lo.z, hi.x, hi.z])
			# Vertex colours are stored as 8-bit.
			quads_ok = quads_ok and flat and want_by_key.has(key) and _col_near(cols[i * 6], want_by_key[key], 0.005)
	_check(quads_ok, "the light-pool mesh holds one floor quad per flame at world_builder's size and tint (%d quads)" % want.size())
	var m := pm.material_override as StandardMaterial3D
	_check(m != null and m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED and m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and m.blend_mode == BaseMaterial3D.BLEND_MODE_ADD \
		and m.vertex_color_use_as_albedo and m.cull_mode == BaseMaterial3D.CULL_DISABLED and m.albedo_texture != null and m.albedo_texture.resource_path == COMMON + "glow.png" \
		and pm.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "the light pools are additive, unshaded, vertex-coloured glow quads")
	# Compatibility reads vertex colours as sRGB and Forward+ as linear: without the flag the pools come out about 9 times as bright as today's.
	_check(m != null and m.vertex_color_is_srgb, "the light pools' vertex colours are read as sRGB, as today's renderer reads them")


# ---------------------------------------------------------------- colliders
func _test_colliders() -> void:
	var expect: Array[String] = []
	var walls := 0
	var circles := 0
	var boxes := 0
	var node_cols := 0
	var ponds := 0
	for w: Dictionary in _world.walls:
		if w.area == _id:
			var b := _nbox(w.box)
			var h := maxf(float(w.height), 3.0)
			expect.append(_sig(["box", b.x1 - b.x0, h, b.z1 - b.z0, (b.x0 + b.x1) / 2.0, h / 2.0, (b.z0 + b.z1) / 2.0]))
			walls += 1
	for p: Dictionary in _world.props:
		if p.area != _id or p.obstacle == null:
			continue
		var o: Dictionary = p.obstacle
		if o.kind == "circle":
			expect.append(_sig(["cyl", o.r, 3.0, o.x, 1.5, o.z]))
			circles += 1
		else:
			expect.append(_sig(["box", o.x1 - o.x0, 3.0, o.z1 - o.z0, (o.x0 + o.x1) / 2.0, 1.5, (o.z0 + o.z1) / 2.0]))
			boxes += 1
	for n: Dictionary in _world.nodes:
		if n.area == _id and float(n.collider) > 0.0:
			expect.append(_sig(["cyl", float(n.collider), 3.0, n.x, 1.5, n.z]))
			node_cols += 1
	if DRAWN_BY.ponds == _id:   # deep water blocks feet
		for r: Dictionary in _world.ponds:
			expect.append(_sig(["box", r.x1 - r.x0, 3.0, r.z1 - r.z0, (r.x0 + r.x1) / 2.0, 1.5, (r.z0 + r.z1) / 2.0]))
			ponds += 1
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
	_check(_sorted(expect) == _sorted(got), "%d static colliders match world.json: %d walls, %d round + %d box props, %d nodes, %d deep ponds" % [expect.size(), walls, circles, boxes, node_cols, ponds])
	_check(body.collision_layer == 1 and body is StaticBody3D, "colliders are one static body on the 'world' layer")
	_see("pond colliders", ponds)


# ---------------------------------------------------------------- occluders
func _test_occluders() -> void:
	var expect: Array[String] = []
	for w: Dictionary in _world.walls:
		if w.area == _id:
			var b := _nbox(w.box)
			if float(w.height) >= Build.OCC_WALL_MIN_HEIGHT and maxf(b.x1 - b.x0, b.z1 - b.z0) >= Build.OCC_WALL_MIN_LENGTH:
				expect.append(_sig([(b.x0 + b.x1) / 2.0, w.height / 2.0, (b.z0 + b.z1) / 2.0, b.x1 - b.x0, w.height, b.z1 - b.z0, 0.0, 1.0]))
	var walls_n := expect.size()
	for p: Dictionary in _world.props:
		if p.area != _id:
			continue
		var spec: Dictionary = _world.propSpecs[p.prop]
		var c: Variant = spec.get("collider")
		if c != null and c.kind == "box":
			var s := float(p.scale)
			var h := float(spec.height) * s
			if h >= Build.OCC_PROP_MIN_HEIGHT and minf(float(c.hw), float(c.hd)) * 2.0 * s >= Build.OCC_PROP_MIN_SIDE:
				var size := Vector3(float(c.hw) * 2.0 * s, h, float(c.hd) * 2.0 * s) * Build.OCC_PROP_SHRINK
				expect.append(_sig([p.x, float(p.y) + size.y / 2.0, p.z, size.x, size.y, size.z, sin(float(p.rot)), cos(float(p.rot))]))
	var got: Array[String] = []
	var ground_ok := true
	for k in _kids("Occluders"):
		var oi := k as OccluderInstance3D
		var bo := oi.occluder as BoxOccluder3D
		if bo == null:
			ground_ok = false
			continue
		got.append(_sig([oi.position.x, oi.position.y, oi.position.z, bo.size.x, bo.size.y, bo.size.z, sin(oi.rotation.y), cos(oi.rotation.y)]))
		ground_ok = ground_ok and bo.size.y > 0.0 and oi.position.y >= bo.size.y / 2.0 - EPS
	_check(_sorted(expect) == _sorted(got), "%d occluders: %d tall long walls and %d large solid box props (as the converter's thresholds say), at their place and size" % [expect.size(), walls_n, expect.size() - walls_n])
	_check(ground_ok, "occluders are boxes that stand on or above the ground")


# ---------------------------------------------------------------- the lighting bake
## DmWorldBuilder.set_area's ambient colour for an area.
func _ambient(a: Dictionary) -> Color:
	var amb: Dictionary = a.ambient
	var sky := Color.html(amb.hemiSky)
	var peak := maxf(sky.r, maxf(sky.g, sky.b))
	if peak > 0.01:
		var luma := 0.2126 * sky.r + 0.7152 * sky.g + 0.0722 * sky.b
		var boost := clampf(maxf(DmWorldBuilder.AMBIENT_FLOOR / peak, DmWorldBuilder.AMBIENT_LUMA_FLOOR / maxf(luma, 0.01)), 1.0, DmWorldBuilder.AMBIENT_MAX_BOOST)
		sky = Color(sky.r * boost, sky.g * boost, sky.b * boost)
	var gnd := Color.html(amb.hemiGround).lerp(sky, DmWorldBuilder.GROUND_LIFT)
	return sky.lerp(gnd, DmWorldBuilder.AMBIENT_GROUND_MIX)


## The area's LightmapGI (client/addons/dm_bake/README.md): it bakes the area's ambient (the colour world_builder.set_area gives it) and the prop lights; when a
## bake sits next to the scene, the node points at it and the bake fits the scene: every mesh the bake recorded is still a mesh at that place in the scene
## (a converter change that moves or renames them makes the bake stale: bake again). An area without a bake has a LightmapGI with no data.
func _test_lightmap(a: Dictionary, scene_path: String) -> void:
	var found := _scene.find_children("*", "LightmapGI", true, false)
	_check(found.size() == 1, "one LightmapGI (%d)" % found.size())
	if found.is_empty():
		return
	var lm := found[0] as LightmapGI
	_check(lm.environment_mode == LightmapGI.ENVIRONMENT_MODE_CUSTOM_COLOR and lm.environment_custom_color.is_equal_approx(_ambient(a))
		and _near(lm.environment_custom_energy, float(_world.lighting.hemiIntensity) * DmWorldBuilder.HEMI_K), "the bake's ambient is set_area's colour for this area, at the hemisphere's energy")
	# The bake's other settings (a different value is a different bake: client/addons/dm_bake/README.md).
	_check(lm.quality == LightmapGI.BAKE_QUALITY_MEDIUM and lm.bounces == 3 and not lm.directional and lm.use_denoiser and lm.max_texture_size == 4096, "the bake's quality (medium), bounces (3), denoiser, no directional lightmap and texture limit")
	var data_path := scene_path.get_basename() + ".lmbake"
	if not ResourceLoader.exists(data_path):
		_check(lm.light_data == null, "no bake yet: the LightmapGI has no data")
		return
	var data := lm.light_data
	_check(data != null and data.resource_path == data_path, "the LightmapGI points at %s" % data_path)
	if data == null:
		return
	_check(not data.get_lightmap_textures().is_empty(), "the bake has its lightmap (%d texture)" % data.get_lightmap_textures().size())
	var missing := []
	for i in data.get_user_count():
		var n := lm.get_node_or_null(data.get_user_path(i))   # the bake stores each mesh's path from the LightmapGI
		if not (n is MeshInstance3D):
			missing.append(String(data.get_user_path(i)))
	_check(data.get_user_count() > 0 and missing.is_empty(), "the bake fits the scene: all %d baked meshes are there (%d missing: %s)" % [data.get_user_count(), missing.size(), str(missing.slice(0, 3))])


# ---------------------------------------------------------------- doors and gates
func _doors_of(area_id: String) -> Array:
	var out: Array = []
	for d: Dictionary in _world.doors:
		if d.a == area_id or d.b == area_id:
			out.append(d)
	return out


func _test_doors() -> void:
	var touching := _doors_of(_id)
	var ids: Array[String] = []
	var floor_acc: Dictionary = {}
	var holders_ok := true
	for d: Dictionary in touching:
		ids.append(d.id)
		_door_seen[d.id] = int(_door_seen.get(d.id, 0)) + 1
		var holder := _scene.get_node_or_null("Doors/%s" % d.id) as Node3D
		if holder == null:
			holders_ok = false
			continue
		holders_ok = holders_ok and holder.get_meta("door_id", "") == d.id and holder.get_meta("areas", []) == [d.a, d.b]
		_merge_into(floor_acc, _floor_quad(holder.get_node_or_null("floor") as MeshInstance3D, d.rect.x0, d.rect.z0, d.rect.x1, d.rect.z1, "chapter", 0.005))
	_check(_kids("Doors").size() == touching.size() and holders_ok, "%d doors touch this area (%s) and no door of another area is in the scene" % [touching.size(), ", ".join(ids)])
	if not touching.is_empty():
		_check_each("the door corridors' floors", floor_acc)
	# Gates: every door but the always-open one has its gate, built closed (world_builder._gates) and then opened for doors that are open
	# (world_builder._apply_unlock_state: set_door_open instant: bars raised and hidden, the collider off).
	for d: Dictionary in touching:
		var holder := _scene.get_node_or_null("Doors/%s" % d.id) as Node3D
		if holder == null:
			continue
		var gate := holder.get_node_or_null("gate") as Node3D
		if d.id == ALWAYS_OPEN_DOOR:
			_check(gate == null and d.open, "%s is the hall with no gate, open" % d.id)
			continue
		if gate == null:
			_check(false, "%s has its gate" % d.id)
			continue
		var problems := _gate_problems(d, gate)
		_check(problems.is_empty(), "gate %s is world_builder's (%s)" % [d.id, "; ".join(problems)])
		# The bars are one MultiMesh: where each one stands is read from the scene file (see _instances_in_file).
		var bars_mm := gate.get_node_or_null("bars/bars") as MultiMeshInstance3D
		var n_bars := int(round(float(d.width) / 0.45))
		var want_bars: Array[Transform3D] = []
		for i in n_bars + 1:
			want_bars.append(Transform3D(Basis.IDENTITY, Vector3(-float(d.width) / 2.0 + i * float(d.width) / n_bars, 2.4, 0)))
		var why := _instances_in_file(bars_mm, want_bars) if bars_mm != null else "no bars"
		_check(why == "", "gate %s: its %d iron bars stand at world_builder's places in the scene file (%s)" % [d.id, n_bars + 1, why])
		var col := gate.get_node_or_null("body/collider") as CollisionShape3D
		var bars := gate.get_node_or_null("bars") as Node3D
		var open: bool = d.open
		_check(col != null and bars != null and col.disabled == open and _near(bars.position.y, 5.0 if open else 0.0) and bars.visible == (not open),
			"gate %s starts %s: the collider is %s, the bars %s" % [d.id, "open" if open else "closed", "off" if open else "solid", "raised and hidden" if open else "down and visible"])


func _gate_problems(d: Dictionary, gate: Node3D) -> Array[String]:
	var bad: Array[String] = []
	var width: float = d.width
	if not (_near_v(gate.position, Vector3(d.cx, 0, d.cz)) and _near(gate.rotation.y, 0.0 if d.axis == "z" else PI / 2.0)):
		bad.append("place or turn")
	var post_ok := true
	var k := 0
	for s in [-1.0, 1.0]:
		var post := gate.get_node_or_null("post_%d" % k) as MeshInstance3D
		k += 1
		post_ok = post_ok and post != null and (post.mesh as BoxMesh).size.is_equal_approx(Vector3(1, 5, 1)) and _near_v(post.position, Vector3(s * (width + 1.0) / 2.0, 2.5, 0))
		var pm: StandardMaterial3D = post.material_override as StandardMaterial3D if post != null else null
		post_ok = post_ok and pm != null and pm.albedo_texture != null and pm.albedo_texture.resource_path == TEX % "stone_wall" and pm.albedo_color.is_equal_approx(DmCompatAlbedo.tint("stone_wall", Color.html("#8a8296"))) \
			and _near(pm.roughness, 0.9) and pm.uv1_triplanar and pm.uv1_world_triplanar and pm.uv1_scale.is_equal_approx(Vector3.ONE / 4.0) and pm.texture_filter == DmWorldBuilder.SHARP
	if not post_ok:
		bad.append("posts")
	var lintel := gate.get_node_or_null("lintel") as MeshInstance3D
	if not (lintel != null and (lintel.mesh as BoxMesh).size.is_equal_approx(Vector3(width + 2.0, 0.9, 1.0)) and _near_v(lintel.position, Vector3(0, 5.2, 0))):
		bad.append("lintel")
	var bars := gate.get_node_or_null("bars") as Node3D
	if bars == null or bars.get_child_count() != 4:
		bad.append("bars group")
		return bad
	var mmi := bars.get_node_or_null("bars") as MultiMeshInstance3D
	var n := int(round(width / 0.45))
	var bars_ok := mmi != null and mmi.multimesh.instance_count == n + 1
	if bars_ok:
		var cyl := mmi.multimesh.mesh as CylinderMesh
		bars_ok = cyl != null and _near(cyl.top_radius, 0.05) and _near(cyl.bottom_radius, 0.05) and _near(cyl.height, 4.8) and cyl.radial_segments == 5
		var bm := mmi.material_override as StandardMaterial3D
		bars_ok = bars_ok and bm != null and bm.albedo_color.is_equal_approx(Color.html("#24212a")) and _near(bm.roughness, 0.6) and _near(bm.metallic, 0.6)
	if not bars_ok:
		bad.append("%d iron bars (count, mesh, material)" % (n + 1))
	var rails_ok := true
	var r := 0
	for y in [0.9, 3.2]:
		var rail := bars.get_node_or_null("rail_%d" % r) as MeshInstance3D
		r += 1
		rails_ok = rails_ok and rail != null and (rail.mesh as BoxMesh).size.is_equal_approx(Vector3(width, 0.08, 0.1)) and _near_v(rail.position, Vector3(0, y, 0))
	if not rails_ok:
		bad.append("rails")
	var seal := bars.get_node_or_null("seal") as MeshInstance3D
	var sm: StandardMaterial3D = seal.material_override as StandardMaterial3D if seal != null else null
	var seal_ok := seal != null and (seal.mesh as QuadMesh).size.is_equal_approx(Vector2(width * 0.9, width * 0.9)) and _near_v(seal.position, Vector3(0, 2.5, 0.12)) \
		and seal.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and sm != null and sm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED \
		and sm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and sm.blend_mode == BaseMaterial3D.BLEND_MODE_ADD and sm.albedo_texture != null \
		and sm.albedo_texture.resource_path == COMMON + "ring.png" and sm.albedo_color.is_equal_approx(Color(0.61, 0.36, 1.0, 0.9)) and sm.cull_mode == BaseMaterial3D.CULL_DISABLED
	if not seal_ok:
		bad.append("seal")
	var col := gate.get_node_or_null("body/collider") as CollisionShape3D
	if not (col != null and col.shape is BoxShape3D and (col.shape as BoxShape3D).size.is_equal_approx(Vector3(width, 5.0, 1.0)) and _near_v(col.position, Vector3(0, 2.5, 0))
			and gate.get_node("body") is StaticBody3D):
		bad.append("solid body")
	return bad


# ---------------------------------------------------------------- navigation
func _all_obstacles() -> Array:
	var grow := DmWorldBuilder.GROW
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
				var ang := TAU * i / 10.0
				pts.append(Vector3(o.x + cos(ang) * (o.r + grow), 0, o.z + sin(ang) * (o.r + grow)))
			out.append([o.x - o.r - grow, o.z - o.r - grow, o.x + o.r + grow, o.z + o.r + grow, pts])
		else:
			var x0: float = o.x0 - grow
			var z0: float = o.z0 - grow
			var x1: float = o.x1 + grow
			var z1: float = o.z1 + grow
			out.append([x0, z0, x1, z1, PackedVector3Array([Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)])])
	for n: Dictionary in _world.nodes:
		if float(n.collider) > 0.0:
			var r: float = float(n.collider) + grow
			var pts2 := PackedVector3Array()
			for i in 10:
				var a2 := TAU * i / 10.0
				pts2.append(Vector3(n.x + cos(a2) * r, 0, n.z + sin(a2) * r))
			out.append([n.x - r, n.z - r, n.x + r, n.z + r, pts2])
	for pd: Dictionary in _world.ponds:
		var x0p: float = pd.x0 - grow
		var z0p: float = pd.z0 - grow
		var x1p: float = pd.x1 + grow
		var z1p: float = pd.z1 + grow
		out.append([x0p, z0p, x1p, z1p, PackedVector3Array([Vector3(x0p, 0, z0p), Vector3(x1p, 0, z0p), Vector3(x1p, 0, z1p), Vector3(x0p, 0, z1p)])])
	return out


## world_builder._bake_region from scratch (same settings), for comparison with the baked mesh stored in the scene.
func _fresh_bake(r: Dictionary) -> NavigationMesh:
	var src := NavigationMeshSourceGeometryData3D.new()
	var a := Vector3(r.x0, 0, r.z0)
	var b := Vector3(r.x1, 0, r.z0)
	var c := Vector3(r.x1, 0, r.z1)
	var d := Vector3(r.x0, 0, r.z1)
	src.add_faces(PackedVector3Array([a, b, c, a, c, d]), Transform3D.IDENTITY)
	for o: Array in _obstacles:
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


func _same_mesh(a: NavigationMesh, b: NavigationMesh) -> bool:
	var va := a.get_vertices()
	var vb := b.get_vertices()
	if a.get_polygon_count() != b.get_polygon_count() or va.size() != vb.size():
		return false
	for i in va.size():
		if va[i].distance_to(vb[i]) > 0.001:
			return false
	return true


func _settings_ok(nm: NavigationMesh) -> bool:
	return _near(nm.cell_size, 0.25) and _near(nm.cell_height, 0.25) and _near(nm.agent_radius, 0.5) and _near(nm.agent_height, 1.75) and _near(nm.agent_max_climb, 0.25) \
		and _near(nm.agent_max_slope, 45.0) and _near(nm.region_min_size, 1.0)


func _map() -> RID:
	return _scene.get_world_3d().navigation_map


func _settle() -> void:
	var map := _map()
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


func _path(from: Vector3, to: Vector3) -> PackedVector3Array:
	return NavigationServer3D.map_get_path(_map(), from, to, true)


func _path_ends_near(from: Vector3, to: Vector3, tol := 1.5) -> bool:
	var p := _path(from, to)
	return p.size() >= 2 and Vector2(p[p.size() - 1].x - to.x, p[p.size() - 1].z - to.z).length() < tol


func _path_length(from: Vector3, to: Vector3) -> float:
	var p := _path(from, to)
	var total := 0.0
	for i in range(1, p.size()):
		total += p[i].distance_to(p[i - 1])
	return total


func _on_mesh(p: Vector3, tol := 0.2) -> bool:
	var c := NavigationServer3D.map_get_closest_point(_map(), p)
	return Vector2(c.x - p.x, c.z - p.z).length() < tol


## Where world_builder._bake_nav puts a door's link ends for `room_id`: the room's edge on the door's centre line, which way is into the room, and the two ends.
func _door_end(d: Dictionary, room_id: String) -> Dictionary:
	var rr: Dictionary = _world.areas[room_id].rect
	if d.axis == "z":
		var low: bool = absf(d.rect.z0 - rr.z1) < 1.2   # the room lies at lower z than the corridor
		var edge: float = rr.z1 if low else rr.z0
		var sg := -1.0 if low else 1.0
		return {"edge": Vector3(d.cx, 0, edge), "into": Vector3(0, 0, sg), "inside": Vector3(d.cx, 0, edge + sg * 0.6), "outside": Vector3(d.cx, 0, edge + sg * 0.4)}
	var low_x: bool = absf(d.rect.x0 - rr.x1) < 1.2
	var edge_x: float = rr.x1 if low_x else rr.x0
	var sgx := -1.0 if low_x else 1.0
	return {"edge": Vector3(edge_x, 0, d.cz), "into": Vector3(sgx, 0, 0), "inside": Vector3(edge_x + sgx * 0.6, 0, d.cz), "outside": Vector3(edge_x + sgx * 0.4, 0, d.cz)}


## A walkable point on the door's centre line a few metres inside the room (props may stand close to the mouth).
func _mouth(d: Dictionary, room_id: String) -> Vector3:
	var e := _door_end(d, room_id)
	for depth in [3.0, 4.5, 6.0, 2.0, 8.0]:
		var p: Vector3 = e.edge + e.into * depth
		if _on_mesh(p):
			return p
	return Vector3.INF


func _test_navigation(a: Dictionary) -> void:
	var rect: Dictionary = a.rect
	var touching := _doors_of(_id)
	var nav := _scene.get_node("Navigation")
	_check(nav.get_child_count() == 1 + touching.size() * 3, "Navigation holds the area's region and, per door, a region and two links (%d nodes)" % nav.get_child_count())
	# The area's region: baked into the scene, equal to a fresh bake, enabled, and short of the walls by the agent's radius.
	var reg := nav.get_node_or_null("area_" + _id) as NavigationRegion3D
	var nm: NavigationMesh = reg.navigation_mesh if reg != null else null
	_check(nm != null and reg.enabled and nm.get_polygon_count() > 0, "the area's navmesh is baked into the scene and enabled (%d polygons)" % (nm.get_polygon_count() if nm != null else 0))
	if nm == null:
		return
	var fresh := _fresh_bake(rect)
	_check(_same_mesh(nm, fresh), "the stored navmesh equals a fresh bake of world.json with world_builder's settings (%d polygons, %d vertices)" % [fresh.get_polygon_count(), fresh.get_vertices().size()])
	_check(_settings_ok(nm), "navmesh settings are world_builder's")
	var inset_ok := true
	for v in nm.get_vertices():
		inset_ok = inset_ok and v.x >= rect.x0 + 0.4 and v.x <= rect.x1 - 0.4 and v.z >= rect.z0 + 0.4 and v.z <= rect.z1 - 0.4
	_check(inset_ok, "the navmesh stops short of the walls by the agent's radius")
	# Door regions and links: open doors are on, sealed ones start off; the links join the corridor to each room across the overlap.
	var door_ok := true
	var link_ok := true
	var bad: Array[String] = []
	for d: Dictionary in touching:
		var dr := nav.get_node_or_null("door_%s" % d.id) as NavigationRegion3D
		if dr == null or dr.navigation_mesh == null:
			door_ok = false
			bad.append(d.id)
			continue
		var df := _fresh_bake(d.rect)
		var this_ok: bool = dr.enabled == d.open and dr.navigation_mesh.get_polygon_count() > 0 and _same_mesh(dr.navigation_mesh, df) and _settings_ok(dr.navigation_mesh)
		door_ok = door_ok and this_ok
		if not this_ok:
			bad.append("%s (region enabled %s, door open %s)" % [d.id, dr.enabled, d.open])
		var k := 0
		for room_id: String in [d.a, d.b]:
			var l := nav.get_node_or_null("link_%s_%d" % [d.id, k]) as NavigationLink3D
			k += 1
			var e := _door_end(d, room_id)
			var l_ok: bool = l != null and l.enabled == d.open and l.bidirectional and l.navigation_layers == 1 and _near_v(l.start_position, e.inside) and _near_v(l.end_position, e.outside)
			link_ok = link_ok and l_ok
			if not l_ok:
				bad.append("%s link %d (enabled %s, door open %s)" % [d.id, k - 1, l.enabled if l != null else "missing", d.open])
	_check(door_ok, "door regions are baked as world_builder bakes them, and enabled exactly when the door is open (%s)" % ", ".join(bad))
	_check(link_ok, "each door's two links join its corridor to the rooms at world_builder's ends, enabled exactly when the door is open (%s)" % ", ".join(bad))

	# Walk it.
	await _settle()
	var start := Vector3.INF
	var mouths: Array[Vector3] = []
	for d: Dictionary in touching:
		var m := _mouth(d, _id)
		mouths.append(m)
		if start == Vector3.INF:
			start = m
	_check(start != Vector3.INF and not mouths.has(Vector3.INF), "every door mouth is a walkable point of the area")
	if start == Vector3.INF:
		return
	# A path crosses the area: the walkable point furthest from the first door's mouth that the map reaches, a good part of the way across.
	var cands: Array[Vector3] = []
	var gx: float = rect.x0 + 2.0
	while gx <= rect.x1 - 2.0:
		var gz: float = rect.z0 + 2.0
		while gz <= rect.z1 - 2.0:
			cands.append(Vector3(gx, 0, gz))
			gz += 2.0
		gx += 2.0
	cands.sort_custom(func(p: Vector3, q: Vector3) -> bool: return p.distance_squared_to(start) > q.distance_squared_to(start))
	var far := Vector3.INF
	var tried := 0
	for c in cands:
		if not _on_mesh(c):
			continue
		tried += 1
		if _path_ends_near(start, c, 0.6):
			far = c
			break
		if tried >= 60:
			break
	var span := maxf(float(rect.x1) - float(rect.x0), float(rect.z1) - float(rect.z0))
	_check(far != Vector3.INF and start.distance_to(far) >= span * 0.5 and _path_length(start, far) >= start.distance_to(far) - EPS,
		"a path crosses the area: %s to %s (%.1f m) through the walkable mesh" % [start, far, start.distance_to(far) if far != Vector3.INF else 0.0])
	# The door mouths are all reachable from the first.
	var mouths_ok := true
	for m in mouths:
		mouths_ok = mouths_ok and _path_ends_near(start, m, 0.6)
	_check(mouths_ok, "all %d door mouths are reachable from each other inside the area" % mouths.size())
	# A box prop blocks the straight line: the path bends round it and never enters its footprint.
	var tested := 0
	var boxes := 0
	var detour_ok := true
	for p: Dictionary in _world.props:
		if p.area != _id or p.obstacle == null or p.obstacle.kind != "box":
			continue
		boxes += 1
		if tested >= 8:
			continue
		var o: Dictionary = p.obstacle
		var zc := (float(o.z0) + float(o.z1)) / 2.0
		var pa := Vector3(float(o.x0) - 2.0, 0, zc)
		var pb := Vector3(float(o.x1) + 2.0, 0, zc)
		if not _in_rect(rect, pa.x, pa.z) or not _in_rect(rect, pb.x, pb.z) or not _on_mesh(pa) or not _on_mesh(pb) or not _path_ends_near(pa, pb, 0.6):
			continue
		tested += 1
		var path := _path(pa, pb)
		for i in range(1, path.size()):
			var seg := path[i] - path[i - 1]
			var steps := maxi(1, int(seg.length() / 0.1))
			for s in steps + 1:
				var q := path[i - 1] + seg * (float(s) / steps)
				if q.x > o.x0 + 0.01 and q.x < o.x1 - 0.01 and q.z > o.z0 + 0.01 and q.z < o.z1 - 0.01:
					detour_ok = false
		if _path_length(pa, pb) <= pa.distance_to(pb) + 0.05:
			detour_ok = false
	_check(detour_ok and (boxes == 0 or tested > 0), "paths bend round box props and stay out of their footprint (%d of %d box props tried)" % [tested, boxes])

	# Gates: sealed, a door blocks the way to the far end of its corridor; open, it is walkable. Opening is what world_builder.set_door_open does: the region and both links.
	var closed: Array = []
	var reach_ok := true
	var sealed_ok := true
	for d: Dictionary in touching:
		var other: String = d.b if d.a == _id else d.a
		var target: Vector3 = _door_end(d, other).outside
		var from := _mouth(d, _id)
		if d.open:
			reach_ok = reach_ok and _path_ends_near(from, target, 1.0)
		else:
			closed.append(d)
			sealed_ok = sealed_ok and not _path_ends_near(from, target, 1.0)
	_check(sealed_ok, "%d sealed gates block the way to their corridors' far ends" % closed.size())
	for d: Dictionary in closed:
		(nav.get_node("door_%s" % d.id) as NavigationRegion3D).enabled = true
		for k in 2:
			(nav.get_node("link_%s_%d" % [d.id, k]) as NavigationLink3D).enabled = true
	if not closed.is_empty():
		await _settle()
	for d: Dictionary in closed:
		var other2: String = d.b if d.a == _id else d.a
		reach_ok = reach_ok and _path_ends_near(_mouth(d, _id), _door_end(d, other2).outside, 1.0)
	_check(reach_ok, "every door's corridor is walkable to its far end once open (%d open from the start, %d opened here)" % [touching.size() - closed.size(), closed.size()])


# ---------------------------------------------------------------- bounds
func _test_bounds(a: Dictionary) -> void:
	var rect: Dictionary = a.rect
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var floors: Array[Node] = []
	for k in _kids("Floor"):
		if String(k.name) == "ground" or String(k.name).begins_with("path_"):
			floors.append(k)
	for d in _kids("Doors"):
		floors.append(d.get_node("floor"))
	for n in floors:
		var mi := n as MeshInstance3D
		var b := mi.global_transform * mi.mesh.get_aabb()
		lo = Vector2(minf(lo.x, b.position.x), minf(lo.y, b.position.z))
		hi = Vector2(maxf(hi.x, b.end.x), maxf(hi.y, b.end.z))
	var want_lo := Vector2(rect.x0 - 0.8, rect.z0 - 0.8)
	var want_hi := Vector2(rect.x1 + 0.8, rect.z1 + 0.8)
	for d in _doors_of(_id):
		want_lo = Vector2(minf(want_lo.x, d.rect.x0), minf(want_lo.y, d.rect.z0))
		want_hi = Vector2(maxf(want_hi.x, d.rect.x1), maxf(want_hi.y, d.rect.z1))
	for p: Dictionary in _world.paths:
		if _centre_area(p) == _id:
			want_lo = Vector2(minf(want_lo.x, p.x0), minf(want_lo.y, p.z0))
			want_hi = Vector2(maxf(want_hi.x, p.x1), maxf(want_hi.y, p.z1))
	_check(lo.distance_to(want_lo) < 0.01 and hi.distance_to(want_hi) < 0.01, "floor bounds %s to %s are the rect plus 0.8 m, the door corridors and the paths" % [lo, hi])
	var inside := true
	for k in _kids("Props"):
		var p := (k as Node3D).position
		inside = inside and _in_rect(rect, p.x, p.z)
	_check(inside, "every prop stands inside the area's rect")


# ---------------------------------------------------------------- what the scenes hold together
## Everything world.json lists is in exactly the scenes it belongs to: nothing is left out and nothing is drawn twice.
func _test_totals(ids: Array[String]) -> void:
	var want := {"paths": _world.paths.size(), "walls": 0, "props": 0, "nodes": 0, "decals": 0, "puddles": 0, "lights": 0, "pond colliders": _world.ponds.size(),
		"hummocks": _world.hummocks.size(), "wing floor quads": 0, "water planes": _world.water.size() + _world.bog.size() + _world.ponds.size()}
	for w: Dictionary in _world.walls:
		want["walls"] += 1 if ids.has(w.area) else 0
	for p: Dictionary in _world.props:
		if ids.has(p.area):
			want["props"] += 1 if _world.propSpecs[p.prop].url != null else 0
			want["lights"] += 1 if (_world.propSpecs[p.prop].has("light") and _world.propSpecs[p.prop].light != null) else 0
	for n: Dictionary in _world.nodes:
		want["nodes"] += 1 if ids.has(n.area) else 0
	for d: Dictionary in _world.decals:
		want["decals"] += 1 if ids.has(d.area) else 0
	for p: Dictionary in _world.puddles:
		want["puddles"] += 1 if ids.has(p.area) else 0
	for f: Dictionary in _world.wingFloor:
		want["wing floor quads"] += 2 if (f.kind == "rug" and f.alt != null) else 1
	for k: String in want:
		_check(int(_seen.get(k, 0)) == int(want[k]), "all %d %s of world.json are in the scenes, each once (scenes hold %d)" % [want[k], k, int(_seen.get(k, 0))])
	# A door is in the scene of each converted area it joins.
	var doors_ok := true
	for d: Dictionary in _world.doors:
		var sides := (1 if ids.has(d.a) else 0) + (1 if ids.has(d.b) else 0)
		doors_ok = doors_ok and int(_door_seen.get(d.id, 0)) == sides
	_check(doors_ok, "each of the %d doors is in the scene of every converted area it joins" % _world.doors.size())
