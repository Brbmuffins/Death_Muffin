class_name DmWorldBuilder
extends Node3D
## Builds the slice's world from godot/data/slice/world.json: floors, walls, props (MultiMesh + StaticBody3D colliders), nodes,
## sigils, prop lights, the baked navmesh, and the moonlit environment. Everything comes from the exported layout.

const TEX := "res://assets/slice/art/textures/%s.webp"

var world: Dictionary
var nav_map: RID
var env: Environment
var moon: DirectionalLight3D
var prop_lights: Array = []   # {node: OmniLight3D, x, z}
var _tex_cache: Dictionary = {}
var nav_region: NavigationRegion3D

func build(w: Dictionary) -> void:
	world = w
	_make_environment()
	_floors()
	_walls_and_colliders()
	_props()
	_nodes()
	_decals()
	_bake_nav()

func _tex(name: String) -> Texture2D:
	if not _tex_cache.has(name):
		_tex_cache[name] = load(TEX % name)
	return _tex_cache[name]

# ---------------------------------------------------------------- environment / lights
func _make_environment() -> void:
	var L: Dictionary = world.lighting
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html(L.background)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC  # web: ACES; Filmic is the closest cheap Compatibility option, tuned by eye
	env.tonemap_exposure = float(L.exposure)
	env.fog_enabled = true
	env.fog_density = float(L.fogDensity) * 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	moon = DirectionalLight3D.new()
	moon.shadow_enabled = true
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	moon.directional_shadow_max_distance = 45.0
	moon.light_energy = float(L.moonIntensity) * 0.55
	moon.shadow_bias = 0.04
	moon.shadow_normal_bias = 1.2
	add_child(moon)
	var mo: Dictionary = L.moonOffset
	moon.look_at_from_position(Vector3(mo.x, mo.y, mo.z), Vector3.ZERO)
	var rim := DirectionalLight3D.new()
	rim.light_color = Color.html(L.rimColor)
	rim.light_energy = float(L.rimIntensity) * 0.3
	add_child(rim)
	var ro: Dictionary = L.rimOffset
	rim.look_at_from_position(Vector3(ro.x, ro.y, ro.z), Vector3.ZERO)
	set_area("chapterhouse")

## Per-area ambient (AREAS[*].ambient): fog colour, hemisphere sky/ground blended into one ambient colour, moon colour.
func set_area(id: String) -> void:
	var a: Dictionary = world.areas[id]
	var amb: Dictionary = a.ambient
	var sky := Color.html(amb.hemiSky)
	var gnd := Color.html(amb.hemiGround)
	env.ambient_light_color = sky.lerp(gnd, 0.3)
	env.ambient_light_energy = float(world.lighting.hemiIntensity) * 1.5
	env.fog_light_color = Color.html(amb.fog).lerp(Color(0.02, 0.015, 0.03), 0.0)
	env.fog_density = float(world.lighting.fogDensity) * 0.55 * (float(amb.fogMult) if not a.safe else 1.0)
	moon.light_color = Color.html(amb.moon)

# ---------------------------------------------------------------- floors
func _floor_mat(theme_key: String, w: float, d: float) -> StandardMaterial3D:
	var f: Dictionary = world.floors[theme_key]
	var m := StandardMaterial3D.new()
	m.albedo_texture = _tex(f.tex)
	m.albedo_color = Color.hex(int(f.color) * 256 + 255)
	m.roughness = float(f.rough)
	m.uv1_scale = Vector3(w / float(f.tile), d / float(f.tile), 1.0)
	return m

func _plane(x0: float, z0: float, x1: float, z1: float, theme_key: String, y: float) -> void:
	var w := x1 - x0
	var d := z1 - z0
	var pm := PlaneMesh.new()
	pm.size = Vector2(w, d)
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.material_override = _floor_mat(theme_key, w, d)
	mi.position = Vector3((x0 + x1) / 2.0, y, (z0 + z1) / 2.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _floors() -> void:
	# Beyond the walls: dark earth swallowed by fog.
	var out := PlaneMesh.new()
	out.size = Vector2(420, 420)
	var om := StandardMaterial3D.new()
	om.albedo_texture = _tex("grave_soil")
	om.albedo_color = Color.html("#3a3440")
	om.roughness = 1.0
	om.uv1_scale = Vector3(60, 60, 1)
	var omi := MeshInstance3D.new()
	omi.mesh = out
	omi.material_override = om
	omi.position = Vector3(20, -0.06, -60)
	omi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(omi)
	for id in world.slice:
		var a: Dictionary = world.areas[id]
		var r: Dictionary = a.rect
		var key := "chapter" if a.theme == "chapter" else "graveyard"
		_plane(r.x0 - 0.8, r.z0 - 0.8, r.x1 + 0.8, r.z1 + 0.8, key, 0.0)
	for d in world.doors:
		if d.open:
			_plane(d.rect.x0, d.rect.z0, d.rect.x1, d.rect.z1, "chapter", 0.005)
	for p in world.paths:
		_plane(p.x0, p.z0, p.x1, p.z1, "nave", 0.008)

# ---------------------------------------------------------------- walls + colliders
func _body(parent: Node, pos: Vector3, shape: Shape3D) -> void:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = pos
	parent.add_child(cs)

func _walls_and_colliders() -> void:
	var body := StaticBody3D.new()
	body.name = "Colliders"
	add_child(body)
	var wall_mats: Dictionary = {}
	for w in world.walls:
		var b: Dictionary = w.box
		var sx: float = b.x1 - b.x0
		var sz: float = b.z1 - b.z0
		var h: float = w.height
		var bm := BoxMesh.new()
		bm.size = Vector3(sx, h, sz)
		var mat: StandardMaterial3D = wall_mats.get(w.texture)
		if mat == null:
			mat = StandardMaterial3D.new()
			mat.albedo_texture = _tex(w.texture)
			mat.albedo_color = Color.hex(int(w.color) * 256 + 255)
			mat.roughness = 0.92
			mat.uv1_triplanar = true
			mat.uv1_world_triplanar = true
			mat.uv1_scale = Vector3.ONE / 4.0
			wall_mats[w.texture] = mat
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.material_override = mat
		mi.position = Vector3((b.x0 + b.x1) / 2.0, h / 2.0, (b.z0 + b.z1) / 2.0)
		add_child(mi)
		var bs := BoxShape3D.new()
		bs.size = Vector3(sx, maxf(h, 3.0), sz)
		_body(body, Vector3(mi.position.x, maxf(h, 3.0) / 2.0, mi.position.z), bs)
	for p in world.props:
		var o: Variant = p.obstacle
		if o == null:
			continue
		if o.kind == "circle":
			var cs := CylinderShape3D.new()
			cs.radius = o.r
			cs.height = 3.0
			_body(body, Vector3(o.x, 1.5, o.z), cs)
		else:
			var bs2 := BoxShape3D.new()
			bs2.size = Vector3(o.x1 - o.x0, 3.0, o.z1 - o.z0)
			_body(body, Vector3((o.x0 + o.x1) / 2.0, 1.5, (o.z0 + o.z1) / 2.0), bs2)
	for n in world.nodes:
		if n.collider > 0.0:
			var cs2 := CylinderShape3D.new()
			cs2.radius = n.collider
			cs2.height = 3.0
			_body(body, Vector3(n.x, 1.5, n.z), cs2)

# ---------------------------------------------------------------- props
func _props() -> void:
	var by_kind: Dictionary = {}
	for p in world.props:
		if not by_kind.has(p.prop):
			by_kind[p.prop] = []
		by_kind[p.prop].append(p)
	for kind in by_kind:
		var spec: Dictionary = world.propSpecs[kind]
		var list: Array = by_kind[kind]
		var parts := DmModels.prop_parts(spec.url, float(spec.height))
		for part in parts:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = part.mesh
			mm.instance_count = list.size()
			for i in list.size():
				var p: Dictionary = list[i]
				var tilt: float = p.tilt
				var basis := Basis.from_euler(Vector3(tilt, p.rot, tilt * 0.6), EULER_ORDER_XYZ) * Basis.from_scale(Vector3.ONE * p.scale)
				var t := Transform3D(basis, Vector3(p.x, p.y, p.z)) * (part.local as Transform3D)
				mm.set_instance_transform(i, t)
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if float(spec.height) >= 1.2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
		if spec.has("light") and spec.light != null:
			for p in list:
				_prop_light(p, spec.light)

func _prop_light(p: Dictionary, L: Dictionary) -> void:
	var col := Color.hex(int(L.color) * 256 + 255)
	var light := OmniLight3D.new()
	light.light_color = col
	light.omni_range = float(L.distance)
	light.light_energy = float(L.intensity) * 0.18
	light.omni_attenuation = 1.3
	var y: float = float(L.y) * float(p.scale) + float(p.y)
	light.position = Vector3(p.x, y, p.z)
	add_child(light)
	prop_lights.append({"node": light, "x": p.x, "z": p.z})
	# The flame itself (the web draws point sprites): a small unshaded glow.
	var sm := SphereMesh.new()
	sm.radius = 0.1
	sm.height = 0.2
	sm.radial_segments = 8
	sm.rings = 4
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_color = col.lightened(0.3)
	var fi := MeshInstance3D.new()
	fi.mesh = sm
	fi.material_override = fm
	fi.position = light.position
	fi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(fi)

## Only lights near the hero are enabled (the Compatibility renderer has a small per-object light budget).
func update_light_lod(fx: float, fz: float) -> void:
	for e in prop_lights:
		var on := Vector2(e.x - fx, e.z - fz).length() < 26.0
		if e.node.visible != on:
			e.node.visible = on

# ---------------------------------------------------------------- gathering nodes (rich nodes of the Graves)
func _nodes() -> void:
	for n in world.nodes:
		var parts := DmModels.prop_parts(n.model, float(n.modelHeight))
		var root := Node3D.new()
		root.position = Vector3(n.x, 0, n.z)
		root.rotation.y = n.rot
		add_child(root)
		for part in parts:
			var mi := MeshInstance3D.new()
			mi.mesh = part.mesh
			mi.transform = part.local
			root.add_child(mi)

# ---------------------------------------------------------------- floor sigils
func _ring_texture() -> ImageTexture:
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var d := Vector2(x - 63.5, y - 63.5).length() / 63.5
			var a := 0.0
			if d < 1.0:
				a = maxf(a, smoothstep(0.06, 0.0, absf(d - 0.92)))
				a = maxf(a, smoothstep(0.05, 0.0, absf(d - 0.72)) * 0.8)
				a = maxf(a, smoothstep(0.05, 0.0, absf(d - 0.38)) * 0.6)
				var ang := atan2(y - 63.5, x - 63.5)
				a = maxf(a, smoothstep(0.03, 0.0, absf(sin(ang * 3.0))) * smoothstep(0.75, 0.4, d) * 0.5)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)

func _decals() -> void:
	var tex := _ring_texture()
	for d in world.decals:
		if d.kind != "sigil":
			continue
		var qm := QuadMesh.new()
		qm.size = Vector2(d.r * 2.0, d.r * 2.0)
		qm.orientation = PlaneMesh.FACE_Y
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_texture = tex
		m.albedo_color = Color(Color.html(d.color), float(d.opacity))
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = m
		mi.position = Vector3(d.x, 0.03, d.z)
		mi.rotation.y = d.rot
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)

# ---------------------------------------------------------------- navigation
func _outline_circle(x: float, z: float, r: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in 10:
		var a := TAU * i / 10.0
		pts.append(Vector3(x + cos(a) * r, 0, z + sin(a) * r))
	return pts

func _outline_box(x0: float, z0: float, x1: float, z1: float) -> PackedVector3Array:
	return PackedVector3Array([Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)])

func _quad_faces(r: Dictionary) -> PackedVector3Array:
	var a := Vector3(r.x0, 0, r.z0)
	var b := Vector3(r.x1, 0, r.z0)
	var c := Vector3(r.x1, 0, r.z1)
	var d := Vector3(r.x0, 0, r.z1)
	return PackedVector3Array([a, b, c, a, c, d])

## Walkable space = union of the slice's area rects + the open door corridor (same as the web's Nav); walls and prop colliders are carved out.
## Projected obstructions are NOT inflated by the agent radius by the baker, so grow them here (the hero's body is 0.45 m).
const GROW := 0.55

func _bake_nav() -> void:
	var nm := NavigationMesh.new()
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.agent_radius = 0.5
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.agent_max_slope = 45.0
	nm.region_min_size = 1.0
	var src := NavigationMeshSourceGeometryData3D.new()
	var faces := PackedVector3Array()
	for id in world.slice:
		faces.append_array(_quad_faces(world.areas[id].rect))
	for d in world.doors:
		if d.open:
			faces.append_array(_quad_faces(d.rect))
	src.add_faces(faces, Transform3D.IDENTITY)
	for w in world.walls:
		var b: Dictionary = w.box
		src.add_projected_obstruction(_outline_box(b.x0, b.z0, b.x1, b.z1), -0.5, 3.0, true)  # walls sit outside the area rects; agent radius erodes the edge
	for p in world.props:
		var o: Variant = p.obstacle
		if o == null:
			continue
		if o.kind == "circle":
			src.add_projected_obstruction(_outline_circle(o.x, o.z, o.r + GROW), -0.5, 3.0, true)
		else:
			src.add_projected_obstruction(_outline_box(o.x0 - GROW, o.z0 - GROW, o.x1 + GROW, o.z1 + GROW), -0.5, 3.0, true)
	for n in world.nodes:
		if n.collider > 0.0:
			src.add_projected_obstruction(_outline_circle(n.x, n.z, n.collider + GROW), -0.5, 3.0, true)
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	nav_region = NavigationRegion3D.new()
	nav_region.navigation_mesh = nm
	add_child(nav_region)
	nav_map = nav_region.get_navigation_map()

func nav_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	return NavigationServer3D.map_get_path(nav_map, from, to, true)

func nav_closest(p: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(nav_map, p)
