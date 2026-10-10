class_name DmWorldBuilder
extends Node3D
## Builds the whole connected world from godot/data/slice/world.json (originally exported from the web game's TS):
## per-area floors, walls, props (MultiMesh + StaticBody3D colliders), gathering nodes, decals, water, light pools, gates, the Depths'
## sample floor, NPCs, one navigation region per area and per door corridor (NavigationLinks join them; doors/areas toggle at runtime),
## and the web renderer's look: ACES tonemap, hemisphere light, FogExp2 (approximated), moon + violet rim, per-area palettes.

const TEX := "res://assets/slice/art/textures/%s.webp"
## Tuning against the web renderer (three.js physical lights are /PI of Godot's energies; ACES differs slightly).
const MOON_K := 0.6
const RIM_K := 0.55
const HEMI_K := 2.0
## Visibility lift on top of the web look (owner: "pretty dark"): exposure multiplier (the Settings brightness multiplies it again) and how far the
## ground half of the hemisphere is pulled toward its sky colour so shadowed floors and the undersides of props are not black.
const EXPOSURE_K := 1.2
const GROUND_LIFT := 0.25
## Dim areas' hemisphere sky is scaled (hue kept) until its brightest channel reaches AMBIENT_FLOOR, at most AMBIENT_MAX_BOOST x; bright areas are untouched.
const AMBIENT_FLOOR := 0.5
const AMBIENT_LUMA_FLOOR := 0.3
## Plain-colour ambient (a Sky-radiance ambient did not respond to ambient_light_energy on the compatibility renderer here: tripling it changed no pixel): the hemisphere sky colour
## eased toward the ground colour by this much, a stand-in for the web's hemisphere light averaged over what the camera sees.
const AMBIENT_GROUND_MIX := 0.3
const AMBIENT_MAX_BOOST := 2.4
const POINT_K := 0.18
const LIGHT_NEAR := 8        # prop lights enabled at once (nearest to the focus)
## Runtime cap on prop lights (graphics quality); LIGHT_NEAR (the most any preset uses) on High and Ultra.
var light_near := LIGHT_NEAR
var base_exposure := 1.0   # the area-independent exposure (lighting.exposure x EXPOSURE_K); brightness scales it
var area_exposure := 1.0   # per-area easing for already-bright skies (set_area)
var preset_lift := 1.0     # graphics-preset compensation (set_preset_lift)
var brightness := 1.0      # Settings -> Brightness
const STREAM_DIST := 95.0    # an area is drawn while its rect is within this many metres of the focus
## WorldView SHADOW_RANGE: tall prop groups (one per kind and area) further than SHADOW_RANGE from the hero stop casting moon shadows
## (the shadow pass was half the frame).
const SHADOW_RANGE := 32.0
## Runtime range (Graphics preset: further on High / Ultra); SHADOW_RANGE on Low / Medium.
var shadow_range := SHADOW_RANGE
var _shadow_cells: Array = []   # {node, x0, z0, x1, z1, on}
var _shadow_t := 0.0
const GROW := 0.55           # prop/node obstruction grow for the navmesh (the baker does not inflate projected obstructions)

var world: Dictionary
var env: Environment
var moon: DirectionalLight3D
var rim: DirectionalLight3D
var prop_lights: Array = []   # {node, x, z, area}
var area_nodes: Dictionary = {}   # id -> Node3D (everything drawn for that area)
var node_views: Dictionary = {}   # gathering node id -> its Node3D (live look; DmNodeViews swaps live/spent on it)
var area_rects: Dictionary = {}
var gates: Dictionary = {}    # door id -> {root, bars, collider, open, door}
var nav_regions: Dictionary = {}   # "area:<id>" / "door:<id>" -> NavigationRegion3D
var nav_links: Dictionary = {}     # door id -> Array[NavigationLink3D]
var unlocked: Dictionary = {}      # area id -> true
var depths_open := false
var current_area := ""
var _tex_cache: Dictionary = {}
var _colliders: StaticBody3D
var _ring_tex: ImageTexture
var _glow_tex: ImageTexture
var _by_area_props: Dictionary = {}
var nav_bake_ms := 0

## See-through cutout (occlusion.ts): walls and props between the camera and the hero dither away inside a screen circle around the hero.
var occlusion_enabled := true
var _occ_mats: Dictionary = {}
const OCC_PROP := preload("res://world/dm_occ_prop.gdshader")
const OCC_WALL := preload("res://world/dm_occ_wall.gdshader")


## Global shader parameters live as long as the process: register them once and remember it here (global_shader_parameter_get_list is
## editor-only: the engine logs "should never be used outside the editor, it can severely damage performance").
static var _occ_globals_added := false

static func _ensure_occ_globals() -> void:
	if _occ_globals_added:
		return
	_occ_globals_added = true
	RenderingServer.global_shader_parameter_add("dm_occ_a", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0.16, 100))
	RenderingServer.global_shader_parameter_add("dm_occ_b", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(1.6, 0, 0, 0))


## Call once per frame with the camera and the hero's world position (updateOcclusion).
func update_occlusion(cam: Camera3D, hero: Vector3) -> void:
	if not occlusion_enabled or cam == null or not cam.is_inside_tree():
		return
	var vp := cam.get_viewport().get_visible_rect().size
	if vp.y <= 0.0:
		return
	var ndc := func(v: Vector3) -> Vector2:
		var s := cam.unproject_position(v)
		return Vector2((s.x / vp.x) * 2.0 - 1.0, 1.0 - (s.y / vp.y) * 2.0)
	var p: Vector2 = ndc.call(Vector3(hero.x, 1.1, hero.z))
	var head: Vector2 = ndc.call(Vector3(hero.x, hero.y + 1.6, hero.z))
	var feet: Vector2 = ndc.call(Vector3(hero.x, 0.0, hero.z))
	var radius := clampf(absf(head.y - feet.y) * 1.05, 0.1, 0.5)
	RenderingServer.global_shader_parameter_set("dm_occ_a", Vector4(p.x, p.y, radius, cam.global_position.distance_to(Vector3(hero.x, 1.1, hero.z))))
	RenderingServer.global_shader_parameter_set("dm_occ_b", Vector4(vp.x / vp.y, 1.0, 0.0, 0.0))


func _occ_prop_material(src: StandardMaterial3D) -> Material:
	var key := src.get_instance_id()
	if _occ_mats.has(key):
		return _occ_mats[key]
	var m := ShaderMaterial.new()
	m.shader = OCC_PROP
	m.set_shader_parameter("albedo", src.albedo_color)
	if src.albedo_texture != null:
		m.set_shader_parameter("albedo_tex", src.albedo_texture)
	if src.normal_enabled and src.normal_texture != null:
		m.set_shader_parameter("normal_tex", src.normal_texture)
		m.set_shader_parameter("has_normal", true)
		m.set_shader_parameter("normal_scale", src.normal_scale)
	if src.roughness_texture != null:
		m.set_shader_parameter("orm_tex", src.roughness_texture)
		m.set_shader_parameter("has_orm", true)
	m.set_shader_parameter("roughness_f", src.roughness)
	m.set_shader_parameter("metallic_f", src.metallic if src.roughness_texture != null else src.metallic)
	_occ_mats[key] = m
	return m


func _occ_wall_material(src: StandardMaterial3D) -> Material:
	var key := src.get_instance_id()
	if _occ_mats.has(key):
		return _occ_mats[key]
	var m := ShaderMaterial.new()
	m.shader = OCC_WALL
	m.set_shader_parameter("albedo", src.albedo_color)
	m.set_shader_parameter("albedo_tex", src.albedo_texture)
	m.set_shader_parameter("uv_scale", src.uv1_scale.x)
	m.set_shader_parameter("roughness_f", src.roughness)
	_occ_mats[key] = m
	return m


## Walls (box meshes with the triplanar stone material) and props (instanced glTF parts) under `root` get the cutout shaders.
func apply_occlusion(root: Node) -> void:
	if not occlusion_enabled:
		return
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.material_override is StandardMaterial3D and (mi.material_override as StandardMaterial3D).uv1_triplanar and mi.mesh is BoxMesh:
			mi.material_override = _occ_wall_material(mi.material_override)
	for n in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mm := (n as MultiMeshInstance3D).multimesh
		if mm == null or mm.mesh == null:
			continue
		var mesh := mm.mesh
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i)
			if mat is StandardMaterial3D and not (mat as StandardMaterial3D).transparency:
				mesh.surface_set_material(i, _occ_prop_material(mat))


func build(w: Dictionary) -> void:
	world = w
	_ensure_occ_globals()
	_make_environment()
	_colliders = StaticBody3D.new()
	_colliders.name = "Colliders"
	add_child(_colliders)
	for id in world.order:
		var n := Node3D.new()
		n.name = "area_%s" % id
		add_child(n)
		area_nodes[id] = n
		area_rects[id] = world.areas[id].rect
		if not world.areas[id].unlock and not world.areas[id].instance:
			unlocked[id] = true
	_floors()
	_walls()
	_all_props()
	_nodes()
	_decals()
	_water()
	_wing_floor()
	_hummocks()
	_gates()
	_depths()
	_npcs()
	apply_occlusion(self)
	_bake_nav()
	_apply_unlock_state()
	set_area("chapterhouse")

func _tex(name: String) -> Texture2D:
	if not _tex_cache.has(name):
		_tex_cache[name] = load(TEX % name)
	return _tex_cache[name]

## Ground and wall textures are seen at grazing angles: trilinear + anisotropic (level comes from the Graphics preset on the viewport).
const SHARP := BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

func _hex(v: Variant) -> Color:
	return Color.hex(int(v) * 256 + 255)

# ---------------------------------------------------------------- environment / lights
func _make_environment() -> void:
	var L: Dictionary = world.lighting
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html(L.background)
	# Hemisphere light: plain-colour ambient (set per area in set_area from the hemisphere's sky and ground colours); no Sky resource is rendered.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = float(L.hemiIntensity) * HEMI_K
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	base_exposure = float(L.exposure) * EXPOSURE_K
	_apply_exposure()
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_density = 1.0
	env.fog_depth_begin = 0.0
	env.fog_depth_curve = 1.0
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	moon = DirectionalLight3D.new()
	moon.shadow_enabled = true
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	moon.directional_shadow_max_distance = 45.0
	moon.light_energy = float(L.moonIntensity) * MOON_K
	moon.shadow_bias = 0.04
	moon.shadow_normal_bias = 1.2
	add_child(moon)
	var mo: Dictionary = L.moonOffset
	moon.look_at_from_position(Vector3(mo.x, mo.y, mo.z), Vector3.ZERO)
	rim = DirectionalLight3D.new()
	rim.light_color = Color.html(L.rimColor)
	rim.light_energy = float(L.rimIntensity) * RIM_K
	add_child(rim)
	var ro: Dictionary = L.rimOffset
	rim.look_at_from_position(Vector3(ro.x, ro.y, ro.z), Vector3.ZERO)

## Settings -> Brightness (0.8 .. 1.3): a plain exposure multiplier, no per-frame cost.
func set_brightness(v: float) -> void:
	brightness = clampf(v, 0.5, 1.6)
	_apply_exposure()

## The graphics preset's brightness compensation (DmGraphicsPreset `lift`): Low/Medium have fewer prop lights and no bloom (Medium also has the
## moon's hard shadows), so they run a little hotter to read as bright as High. Exposure: both presets have plenty of highlight headroom.
func set_preset_lift(v: float) -> void:
	preset_lift = v
	_apply_exposure()

func _apply_exposure() -> void:
	if env != null:
		env.tonemap_exposure = base_exposure * brightness * area_exposure * preset_lift

## Per-area ambient (AREAS[*].ambient): fog colour + density multiplier, hemisphere sky/ground, moon colour.
func set_area(id: String) -> void:
	current_area = id
	var a: Dictionary = world.areas[id]
	var amb: Dictionary = a.ambient
	var sky := Color.html(amb.hemiSky)
	var peak := maxf(sky.r, maxf(sky.g, sky.b))
	if peak > 0.01:
		var luma := 0.2126 * sky.r + 0.7152 * sky.g + 0.0722 * sky.b   # blue-violet skies are bright to the eye in channel terms but not in luma
		var boost := clampf(maxf(AMBIENT_FLOOR / peak, AMBIENT_LUMA_FLOOR / maxf(luma, 0.01)), 1.0, AMBIENT_MAX_BOOST)
		sky = Color(sky.r * boost, sky.g * boost, sky.b * boost)
	var gnd := Color.html(amb.hemiGround).lerp(sky, GROUND_LIFT)
	# Areas whose sky is already bright (Acre, the Alchemist Wing) keep their old brightness: exposure eases back a little there.
	area_exposure = clampf(1.0 - (peak - 0.5) * 0.8, 0.88, 1.0)
	_apply_exposure()
	env.ambient_light_color = sky.lerp(gnd, AMBIENT_GROUND_MIX)
	env.fog_light_color = Color.html(amb.fog)
	# Web FogExp2 = 1 - exp(-(0.014 m d)^2); Godot's depth fog (smoothstep to `end`) tracks it with end ~ 130 / m.
	var m: float = float(amb.fogMult) if not a.safe else 1.0
	env.fog_depth_end = 130.0 / maxf(0.2, m)
	moon.light_color = Color.html(amb.moon)

# ---------------------------------------------------------------- floors
func _floor_mat(theme_key: String, w: float, d: float) -> StandardMaterial3D:
	var f: Dictionary = world.floors[theme_key]
	var m := StandardMaterial3D.new()
	m.albedo_texture = _tex(f.tex)
	m.texture_filter = SHARP
	m.albedo_color = _hex(f.color)
	m.roughness = float(f.rough)
	m.uv1_scale = Vector3(w / float(f.tile), d / float(f.tile), 1.0)
	if f.has("glow"):
		m.emission_enabled = true
		m.emission = _hex(f.glow)
		m.emission_texture = _tex(f.tex)
		m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY  # three: emissive colour x emissiveMap (Godot's default ADDs the texture)
	return m

## Floors are tiled (FLOOR_TILE m): the Compatibility renderer shades an object with every light whose range touches it, so one plane
## per area ran all 8 prop lights on every floor pixel; a tile only gets the 1-3 lights that reach it. UVs are world-anchored in the mesh
## (the web sets UVs from world position), so one material per theme serves every tile and adjacent tiles line up.
const FLOOR_TILE := 12.0
const OUTSIDE_TILE := 60.0   # the dark earth beyond the walls
var _floor_mats: Dictionary = {}

func _theme_mat(theme_key: String) -> StandardMaterial3D:
	if not _floor_mats.has(theme_key):
		var m := _floor_mat(theme_key, 1.0, 1.0)
		var f: Dictionary = world.floors[theme_key]
		m.uv1_scale = Vector3.ONE
		_floor_mats[theme_key] = m
	return _floor_mats[theme_key]

func _plane(parent: Node3D, x0: float, z0: float, x1: float, z1: float, theme_key: String, y: float, tile := FLOOR_TILE) -> MeshInstance3D:
	return _plane_mat(parent, x0, z0, x1, z1, _theme_mat(theme_key), float(world.floors[theme_key].tile), y, tile)

## Tiles of up to `tile` m covering (x0, z0)-(x1, z1) with ONE shared material; UVs are world metres / `t` (+ `uv0`, the anchor).
func _plane_mat(parent: Node3D, x0: float, z0: float, x1: float, z1: float, mat: Material, t: float, y: float, tile: float, uv0 := Vector2.ZERO) -> MeshInstance3D:
	var last: MeshInstance3D = null
	var nx := maxi(1, ceili((x1 - x0) / tile))
	var nz := maxi(1, ceili((z1 - z0) / tile))
	for ix in nx:
		for iz in nz:
			var ax := lerpf(x0, x1, float(ix) / nx)
			var bx := lerpf(x0, x1, float(ix + 1) / nx)
			var az := lerpf(z0, z1, float(iz) / nz)
			var bz := lerpf(z0, z1, float(iz + 1) / nz)
			var cx := (ax + bx) / 2.0
			var cz := (az + bz) / 2.0
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			st.set_normal(Vector3.UP)
			var corners := [Vector2(ax, az), Vector2(bx, az), Vector2(bx, bz), Vector2(ax, az), Vector2(bx, bz), Vector2(ax, bz)]
			for c: Vector2 in corners:
				st.set_uv((c - uv0) / t)
				st.add_vertex(Vector3(c.x - cx, 0.0, c.y - cz))
			st.generate_tangents()
			var mi := MeshInstance3D.new()
			mi.mesh = st.commit()
			mi.material_override = mat
			mi.position = Vector3(cx, y, cz)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(mi)
			last = mi
	return last

func _floors() -> void:
	# Beyond the walls: dark earth swallowed by fog.
	# (tiled 30 m like the floors, so the lights along the outer walls only shade the strip they reach)
	var om := StandardMaterial3D.new()
	om.albedo_texture = _tex("grave_soil")
	om.texture_filter = SHARP
	om.albedo_color = Color.html("#3a3440")
	om.roughness = 1.0
	var outside := Node3D.new()
	outside.name = "outside"
	add_child(outside)
	# One shared material (the soil repeats every 7 m, anchored at the square's corner) on 60 m tiles.
	_plane_mat(outside, -190.0, -270.0, 230.0, 150.0, om, 7.0, -0.06, OUTSIDE_TILE, Vector2(-190.0, -270.0))
	for id in world.order:
		var a: Dictionary = world.areas[id]
		var r: Dictionary = a.rect
		_plane(area_nodes[id], r.x0 - 0.8, r.z0 - 0.8, r.x1 + 0.8, r.z1 + 0.8, a.theme, 0.0)
	var fixed := Node3D.new()
	fixed.name = "fixed"
	add_child(fixed)
	for d in world.doors:
		_plane(fixed, d.rect.x0, d.rect.z0, d.rect.x1, d.rect.z1, "chapter", 0.005)
	for p in world.paths:
		_plane(fixed, p.x0, p.z0, p.x1, p.z1, "nave", 0.008)

# ---------------------------------------------------------------- walls + colliders
func _body(pos: Vector3, shape: Shape3D, parent: Node = null) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = pos
	(parent if parent != null else _colliders).add_child(cs)
	return cs

## A wall's box with its corners ordered (a few web segments, e.g. the Coliseum's arena walls, are written right-to-left, so the TS box has a negative extent).
func _nbox(b: Dictionary) -> Dictionary:
	return {"x0": minf(b.x0, b.x1), "x1": maxf(b.x0, b.x1), "z0": minf(b.z0, b.z1), "z1": maxf(b.z0, b.z1)}

func _wall_list(parent: Node3D, walls: Array, mats: Dictionary, collide := true) -> void:
	for w in walls:
		var b: Dictionary = _nbox(w.box)
		var sx: float = b.x1 - b.x0
		var sz: float = b.z1 - b.z0
		var h: float = w.height
		var bm := BoxMesh.new()
		bm.size = Vector3(sx, h, sz)
		var mat: StandardMaterial3D = mats.get(w.texture)
		if mat == null:
			mat = StandardMaterial3D.new()
			mat.albedo_texture = _tex(w.texture)
			mat.texture_filter = SHARP
			mat.albedo_color = _hex(w.color)
			mat.roughness = 0.92
			mat.uv1_triplanar = true
			mat.uv1_world_triplanar = true
			mat.uv1_scale = Vector3.ONE / 4.0
			mats[w.texture] = mat
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.material_override = mat
		mi.position = Vector3((b.x0 + b.x1) / 2.0, h / 2.0, (b.z0 + b.z1) / 2.0)
		parent.add_child(mi)
		if collide:
			var bs := BoxShape3D.new()
			bs.size = Vector3(sx, maxf(h, 3.0), sz)
			_body(Vector3(mi.position.x, maxf(h, 3.0) / 2.0, mi.position.z), bs)

func _walls() -> void:
	var mats: Dictionary = {}
	var by_area: Dictionary = {}
	for w in world.walls:
		if not by_area.has(w.area):
			by_area[w.area] = []
		by_area[w.area].append(w)
	for id in by_area:
		_wall_list(area_nodes[id], by_area[id], mats)

# ---------------------------------------------------------------- props
func _all_props() -> void:
	var list: Array = world.props.duplicate()
	list.append_array(world.depths.props)
	for p in list:
		var o: Variant = p.obstacle
		if o != null:
			if o.kind == "circle":
				var cs := CylinderShape3D.new()
				cs.radius = o.r
				cs.height = 3.0
				_body(Vector3(o.x, 1.5, o.z), cs)
			else:
				var bs := BoxShape3D.new()
				bs.size = Vector3(o.x1 - o.x0, 3.0, o.z1 - o.z0)
				_body(Vector3((o.x0 + o.x1) / 2.0, 1.5, (o.z0 + o.z1) / 2.0), bs)
		if not _by_area_props.has(p.area):
			_by_area_props[p.area] = {}
		var kinds: Dictionary = _by_area_props[p.area]
		if not kinds.has(p.prop):
			kinds[p.prop] = []
		kinds[p.prop].append(p)
	for area in _by_area_props:
		var parent: Node3D = area_nodes[area]
		var kinds: Dictionary = _by_area_props[area]
		var pool_pos: Array = []
		for kind in kinds:
			var spec: Dictionary = world.propSpecs[kind]
			var plist: Array = kinds[kind]
			if spec.url != null:
				_prop_batch(parent, spec, plist)
			if spec.has("light") and spec.light != null:
				for p in plist:
					_prop_light(parent, p, spec.light, area)
					pool_pos.append({"x": p.x, "z": p.z, "y": float(spec.light.y) * float(p.scale), "L": spec.light})
		_light_pools(parent, pool_pos, area)

func _prop_xf(p: Dictionary) -> Transform3D:
	var tilt: float = p.tilt
	var basis := Basis.from_euler(Vector3(tilt, p.rot, tilt * 0.6), EULER_ORDER_XYZ) * Basis.from_scale(Vector3.ONE * p.scale)
	return Transform3D(basis, Vector3(p.x, p.y, p.z))

## One MultiMeshInstance3D per (prop kind part, area): the instances of a kind are drawn in one call (the Depths floor batches its own props the same way).
## At most LIGHT_NEAR (8) prop lights are on at once, which is also Compatibility's per-mesh light limit, so a group as wide as its area can never lose a light.
## The shadow cell of a tall group is its instances' bounds: it casts moon shadows while the hero is within shadow_range of them.
func _prop_batch(parent: Node3D, spec: Dictionary, plist: Array) -> void:
	var parts := DmModels.prop_parts(spec.url, float(spec.height))
	var casts := float(spec.height) > 1.5
	var x0 := INF
	var z0 := INF
	var x1 := -INF
	var z1 := -INF
	for p in plist:
		x0 = minf(x0, float(p.x))
		z0 = minf(z0, float(p.z))
		x1 = maxf(x1, float(p.x))
		z1 = maxf(z1, float(p.z))
	for part in parts:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = part.mesh
		mm.instance_count = plist.size()
		for i in plist.size():
			mm.set_instance_transform(i, _prop_xf(plist[i]) * (part.local as Transform3D))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.set_meta("dm_prop", true)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)
		if casts:
			_shadow_cells.append({"node": mmi, "x0": x0, "z0": z0, "x1": x1, "z1": z1, "on": true})

func _prop_light(parent: Node3D, p: Dictionary, L: Dictionary, area: String) -> void:
	var col := _hex(L.color)
	var light := OmniLight3D.new()
	light.light_color = col
	light.omni_range = float(L.distance)
	light.light_energy = float(L.intensity) * POINT_K
	light.omni_attenuation = 1.3
	light.position = Vector3(p.x, float(L.y) * float(p.scale) + float(p.y), p.z)
	light.visible = false
	parent.add_child(light)
	prop_lights.append({"node": light, "x": p.x, "z": p.z, "area": area})
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
	parent.add_child(fi)

func _glow_texture() -> ImageTexture:
	if _glow_tex == null:
		var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		for y in 64:
			for x in 64:
				var d := Vector2(x - 31.5, y - 31.5).length() / 31.5
				var a := clampf(1.0 - d, 0.0, 1.0)
				a = a * a * (3.0 - 2.0 * a)
				img.set_pixel(x, y, Color(1, 1, 1, a))
		_glow_tex = ImageTexture.create_from_image(img)
	return _glow_tex

## Floor light pools under every flame (WorldView.buildPools): one vertex-coloured additive mesh per area.
func _light_pools(parent: Node3D, srcs: Array, area: String) -> void:
	if srcs.is_empty():
		return
	var tone := {"gain": 1.0, "scale": 1.0}
	if area == "nave":
		tone = {"gain": 0.68, "scale": 0.8}
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in srcs:
		var L: Dictionary = s.L
		var r: float = float(L.distance) * 0.42 * float(tone.scale)
		var c := _hex(L.pool if L.has("pool") and L.pool != null else 0xc9864a) * (0.32 * float(tone.gain))
		c.a = 1.0
		var x: float = s.x
		var z: float = s.z
		var q := [Vector3(x - r, 0.015, z - r), Vector3(x + r, 0.015, z - r), Vector3(x + r, 0.015, z + r), Vector3(x - r, 0.015, z + r)]
		var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_color(c)
			st.set_uv(uv[i])
			st.add_vertex(q[i])
	var mesh := st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = _glow_texture()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

## Only the lights nearest the focus (in drawn areas) are on: the Compatibility renderer has a small per-object light budget.
func update_light_lod(fx: float, fz: float) -> void:
	var cand: Array = []
	for e in prop_lights:
		var an: Node3D = area_nodes[e.area]
		if not an.visible:
			e.node.visible = false
			continue
		var d := Vector2(e.x - fx, e.z - fz).length()
		if d < 40.0:
			cand.append([d, e])
		else:
			e.node.visible = false
	cand.sort_custom(func(a, b): return a[0] < b[0])
	for i in cand.size():
		cand[i][1].node.visible = i < light_near

var _lod_t := 0.0
var _lod_x := 1e9
var _lod_z := 1e9
var _lod_near := -1
var _lod_areas := -1

## Per-frame entry for update_light_lod: the budget (nearest N of the lights within 40 m) only needs a fresh scan + sort when the focus moved,
## the preset's N changed or an area was streamed in / out (it ran every frame, ~0.5 ms with the Nave's lights); otherwise at most every 100 ms.
func tick_light_lod(fx: float, fz: float, dt: float) -> void:
	var mask := 0
	var bit := 1
	for id in world.order:
		if (area_nodes[id] as Node3D).visible:
			mask |= bit
		bit <<= 1
	_lod_t -= dt
	if _lod_t > 0.0 and mask == _lod_areas and light_near == _lod_near and absf(fx - _lod_x) + absf(fz - _lod_z) < 1.5:
		return
	_lod_t = 0.1
	_lod_areas = mask
	_lod_near = light_near
	_lod_x = fx
	_lod_z = fz
	update_light_lod(fx, fz)

## Cells further than SHADOW_RANGE from the hero stop casting moon shadows (WorldView); re-checked 4x a second, toggled on change only.
func update_shadow_cells(fx: float, fz: float, dt: float) -> void:
	_shadow_t -= dt
	if _shadow_t > 0.0:
		return
	_shadow_t = 0.25
	# A rebuilt Depths floor frees its prop cells (clear_depths_floor): drop those entries.
	var i := _shadow_cells.size() - 1
	while i >= 0:
		if not is_instance_valid(_shadow_cells[i].node):
			_shadow_cells.remove_at(i)
		i -= 1
	for c in _shadow_cells:
		var dx := maxf(maxf(float(c.x0) - fx, fx - float(c.x1)), 0.0)
		var dz := maxf(maxf(float(c.z0) - fz, fz - float(c.z1)), 0.0)
		var on := dx * dx + dz * dz < shadow_range * shadow_range
		if on != bool(c.on):
			c.on = on
			(c.node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Streaming: draw only the areas near the focus (areas beyond the fog are skipped entirely).
func update_streaming(fx: float, fz: float) -> void:
	for id in world.order:
		var r: Dictionary = area_rects[id]
		var dx := maxf(maxf(r.x0 - fx, fx - r.x1), 0.0)
		var dz := maxf(maxf(r.z0 - fz, fz - r.z1), 0.0)
		var show := Vector2(dx, dz).length() < STREAM_DIST
		if area_nodes[id].visible != show:
			area_nodes[id].visible = show

func area_at(x: float, z: float) -> String:
	for id in world.order:
		var r: Dictionary = area_rects[id]
		if x >= r.x0 and x <= r.x1 and z >= r.z0 and z <= r.z1:
			return id
	return ""

# ---------------------------------------------------------------- gathering nodes
func _node_standin(n: Dictionary, parent: Node3D) -> void:
	var tint := Color.html(n.tint)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.21, 0.28, 0.16)
	m.roughness = 0.9
	if n.kind == "herb":
		var st := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.03
		cm.bottom_radius = 0.06
		cm.height = 0.4
		cm.radial_segments = 5
		st.mesh = cm
		st.material_override = m
		st.position = Vector3(0, 0.2, 0)
		parent.add_child(st)
		var cap := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.16
		sm.height = 0.26
		sm.radial_segments = 8
		sm.rings = 4
		cap.mesh = sm
		var cmat := StandardMaterial3D.new()
		cmat.albedo_color = tint
		cmat.emission_enabled = true
		cmat.emission = tint
		cmat.emission_energy_multiplier = 0.7
		cap.material_override = cmat
		cap.position = Vector3(0, 0.45, 0)
		parent.add_child(cap)
	elif n.kind == "pool":
		var qm := QuadMesh.new()
		qm.size = Vector2(1.6, 1.6)
		qm.orientation = PlaneMesh.FACE_Y
		var rm := StandardMaterial3D.new()
		rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		rm.albedo_texture = _ring_texture()
		rm.texture_filter = SHARP
		rm.albedo_color = Color(tint.r * 2.0, tint.g * 2.0, tint.b * 2.0, 0.28)
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = rm
		mi.position = Vector3(0, 0.09, 0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
	elif n.kind == "tree":
		var tm := MeshInstance3D.new()
		var cm2 := CylinderMesh.new()
		cm2.top_radius = 0.2
		cm2.bottom_radius = 0.35
		cm2.height = 2.4
		cm2.radial_segments = 7
		tm.mesh = cm2
		var tmat := StandardMaterial3D.new()
		tmat.albedo_color = Color(0.24, 0.18, 0.14)
		tm.material_override = tmat
		tm.position = Vector3(0, 1.2, 0)
		parent.add_child(tm)

func _nodes() -> void:
	for n in world.nodes:
		var parent := Node3D.new()
		parent.position = Vector3(n.x, 0.04, n.z)
		parent.rotation.y = n.rot
		area_nodes[n.area].add_child(parent)
		node_views[n.id] = parent
		if n.model != null:
			for part in DmModels.prop_parts(n.model, float(n.modelHeight)):
				var mi := MeshInstance3D.new()
				mi.mesh = part.mesh
				mi.transform = part.local
				parent.add_child(mi)
			if n.kind == "seam" or n.kind == "geode":
				# Ore tint: a small emissive crystal overlay (the web keeps the vein colour out of the baked model).
				var tint := Color.html(n.tint)
				var vm := StandardMaterial3D.new()
				vm.albedo_color = tint
				vm.emission_enabled = true
				vm.emission = tint
				vm.emission_energy_multiplier = 0.9 if n.kind == "geode" else 0.55
				for sh in [[0.2, 0.5, 0.45], [-0.25, 0.45, 0.42], [0.45, 0.35, 0.3]]:
					var bm := BoxMesh.new()
					bm.size = Vector3(0.12, 0.34, 0.12)
					var vi := MeshInstance3D.new()
					vi.mesh = bm
					vi.material_override = vm
					vi.position = Vector3(sh[0], sh[1] * 0.6, sh[2] * 0.4)
					vi.rotation = Vector3(0.3, sh[0] * 3.0, sh[0])
					parent.add_child(vi)
		else:
			_node_standin(n, parent)
		var cs: float = float(n.collider)
		if cs > 0.0:
			var cyl := CylinderShape3D.new()
			cyl.radius = cs
			cyl.height = 3.0
			_body(Vector3(n.x, 1.5, n.z), cyl)

# ---------------------------------------------------------------- decals, water, wing floor, hummocks
const RING_PX := 256   # was 128: the thin sigil lines were upscaled 2x+ on big ground quads (and had no mipmaps, so they shimmered when minified)

func _ring_texture() -> ImageTexture:
	if _ring_tex != null:
		return _ring_tex
	var img := Image.create(RING_PX, RING_PX, true, Image.FORMAT_RGBA8)
	var c := (RING_PX - 1) * 0.5
	for y in RING_PX:
		for x in RING_PX:
			var d := Vector2(x - c, y - c).length() / c
			var a := 0.0
			if d < 1.0:
				a = maxf(a, smoothstep(0.06, 0.0, absf(d - 0.92)))
				a = maxf(a, smoothstep(0.05, 0.0, absf(d - 0.72)) * 0.8)
				a = maxf(a, smoothstep(0.05, 0.0, absf(d - 0.38)) * 0.6)
				var ang := atan2(y - c, x - c)
				a = maxf(a, smoothstep(0.03, 0.0, absf(sin(ang * 3.0))) * smoothstep(0.75, 0.4, d) * 0.5)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	_ring_tex = ImageTexture.create_from_image(img)
	return _ring_tex

func _decals() -> void:
	var ring := _ring_texture()
	var glow := _glow_texture()
	for d in world.decals:
		var qm := QuadMesh.new()
		qm.size = Vector2(d.r * 2.0, d.r * 2.0)
		qm.orientation = PlaneMesh.FACE_Y
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var col := Color.html(d.color)
		if d.kind == "sigil":
			m.albedo_texture = ring
			m.texture_filter = SHARP
			m.albedo_color = Color(col, float(d.opacity))
		else:
			# Blood and cracks: a dark soft stain (the web paints irregular canvas shapes).
			m.albedo_texture = glow
			m.texture_filter = SHARP
			m.albedo_color = Color(col.r * 0.6, col.g * 0.6, col.b * 0.6, float(d.opacity) * 0.8)
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = m
		mi.position = Vector3(d.x, 0.03 if d.kind == "sigil" else 0.02, d.z)
		mi.rotation.y = d.rot
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		area_nodes[d.area].add_child(mi)

func _water_plane(parent: Node3D, r: Dictionary, color: Color, alpha: float) -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(r.x1 - r.x0, r.z1 - r.z0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.16
	m.metallic = 0.1
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.material_override = m
	mi.position = Vector3((r.x0 + r.x1) / 2.0, 0.06, (r.z0 + r.z1) / 2.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

func _water() -> void:
	for r in world.water:
		_water_plane(area_nodes["nave"], r, Color.html("#15142a"), 0.72)
	for r in world.bog:
		_water_plane(area_nodes["fen"], r, Color.html("#0f2a2a"), 0.82)
	for r in world.ponds:
		_water_plane(area_nodes["acre"], r, Color.html("#15142a"), 0.72)
		# Deep water blocks feet (WorldView.registerWalls).
		var bs := BoxShape3D.new()
		bs.size = Vector3(r.x1 - r.x0, 3.0, r.z1 - r.z0)
		_body(Vector3((r.x0 + r.x1) / 2.0, 1.5, (r.z0 + r.z1) / 2.0), bs)
	for p in world.puddles:
		var qm := QuadMesh.new()
		qm.size = Vector2(p.r * 2.0 * float(p.sx), p.r * 2.0)
		qm.orientation = PlaneMesh.FACE_Y
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_texture = _glow_texture()
		m.albedo_color = Color(0.06, 0.07, 0.14, 0.75)
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = m
		mi.position = Vector3(p.x, 0.025, p.z)
		mi.rotation.y = p.rot
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		area_nodes[p.area].add_child(mi)

func _wing_floor() -> void:
	for f in world.wingFloor:
		var qm := QuadMesh.new()
		qm.size = Vector2(f.w, f.d)
		qm.orientation = PlaneMesh.FACE_Y
		var col := Color.html(f.color)
		var m := StandardMaterial3D.new()
		m.roughness = 1.0
		if f.kind == "rug":
			m.albedo_color = col * 0.45
		else:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_texture = _glow_texture()
			m.albedo_color = Color(col, 0.8)
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = m
		mi.position = Vector3(f.x, 0.012 if f.kind == "rug" else 0.014, f.z)
		mi.rotation.y = f.rot
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		area_nodes["alchemist_wing"].add_child(mi)
		if f.kind == "rug" and f.alt != null:
			var tm := QuadMesh.new()
			tm.size = Vector2(f.w - 0.5, f.d - 0.5)
			tm.orientation = PlaneMesh.FACE_Y
			var tmat := StandardMaterial3D.new()
			tmat.roughness = 1.0
			tmat.albedo_color = col * 0.8
			var ti := MeshInstance3D.new()
			ti.mesh = tm
			ti.material_override = tmat
			ti.position = Vector3(f.x, 0.016, f.z)
			ti.rotation.y = f.rot
			ti.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			area_nodes["alchemist_wing"].add_child(ti)

func _hummocks() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.html("#46574a")
	mat.roughness = 1.0
	mat.emission_enabled = true
	mat.emission = Color.html("#0a2622")
	mat.emission_energy_multiplier = 0.5
	mat.albedo_color = mat.albedo_color * 0.7
	var cm := CylinderMesh.new()
	cm.top_radius = 0.9
	cm.bottom_radius = 1.0
	cm.height = 0.34
	cm.radial_segments = 18
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = cm
	mm.instance_count = world.hummocks.size()
	for i in world.hummocks.size():
		var h: Dictionary = world.hummocks[i]
		var t := Transform3D(Basis.from_scale(Vector3(h.r, 1.0, h.r)), Vector3(h.x, 0.17, h.z))
		mm.set_instance_transform(i, t)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	area_nodes["fen"].add_child(mmi)

# ---------------------------------------------------------------- gates (sealed doors)
func _gates() -> void:
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = Color.html("#24212a")
	bar_mat.roughness = 0.6
	bar_mat.metallic = 0.6
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_texture = _tex("stone_wall")
	post_mat.texture_filter = SHARP
	post_mat.albedo_color = Color.html("#8a8296")
	post_mat.roughness = 0.9
	post_mat.uv1_triplanar = true
	post_mat.uv1_world_triplanar = true
	post_mat.uv1_scale = Vector3.ONE / 4.0
	var seal_mat := StandardMaterial3D.new()
	seal_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	seal_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	seal_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	seal_mat.albedo_texture = _ring_texture()
	seal_mat.texture_filter = SHARP
	seal_mat.albedo_color = Color(0.61, 0.36, 1.0, 0.9)
	seal_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for d in world.doors:
		if d.id == "chapter_graves":
			continue  # always open
		var width: float = d.width
		var root := Node3D.new()
		root.position = Vector3(d.cx, 0, d.cz)
		root.rotation.y = 0.0 if d.axis == "z" else PI / 2.0
		add_child(root)
		for s in [-1.0, 1.0]:
			var post := MeshInstance3D.new()
			var pb := BoxMesh.new()
			pb.size = Vector3(1, 5, 1)
			post.mesh = pb
			post.material_override = post_mat
			post.position = Vector3(s * (width + 1.0) / 2.0, 2.5, 0)
			root.add_child(post)
		var lintel := MeshInstance3D.new()
		var lb := BoxMesh.new()
		lb.size = Vector3(width + 2.0, 0.9, 1.0)
		lintel.mesh = lb
		lintel.material_override = post_mat
		lintel.position = Vector3(0, 5.2, 0)
		root.add_child(lintel)
		var bars := Node3D.new()
		root.add_child(bars)
		var n := int(round(width / 0.45))
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.05
		cyl.bottom_radius = 0.05
		cyl.height = 4.8
		cyl.radial_segments = 5
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = cyl
		mm.instance_count = n + 1
		for i in n + 1:
			mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(-width / 2.0 + i * width / n, 2.4, 0)))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = bar_mat
		bars.add_child(mmi)
		for y in [0.9, 3.2]:
			var rail := MeshInstance3D.new()
			var rb := BoxMesh.new()
			rb.size = Vector3(width, 0.08, 0.1)
			rail.mesh = rb
			rail.material_override = bar_mat
			rail.position = Vector3(0, y, 0)
			bars.add_child(rail)
		var seal := MeshInstance3D.new()
		var sq := QuadMesh.new()
		sq.size = Vector2(width * 0.9, width * 0.9)
		seal.mesh = sq
		seal.material_override = seal_mat
		seal.position = Vector3(0, 2.5, 0.12)
		seal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bars.add_child(seal)
		# The gate body: a solid collider across the corridor (the web's nav simply has no walkable corridor while sealed).
		var body := StaticBody3D.new()
		body.position = Vector3(d.cx, 0, d.cz)
		body.rotation.y = root.rotation.y
		add_child(body)
		var bs := BoxShape3D.new()
		bs.size = Vector3(width, 5.0, 1.0)
		var cs := CollisionShape3D.new()
		cs.shape = bs
		cs.position = Vector3(0, 2.5, 0)
		body.add_child(cs)
		gates[d.id] = {"root": root, "bars": bars, "collider": cs, "open": false}

func set_door_open(id: String, open: bool, instant := false) -> void:
	if not gates.has(id):
		return
	var g: Dictionary = gates[id]
	if g.open == open:
		return
	g.open = open
	(g.collider as CollisionShape3D).set_deferred("disabled", open)
	var bars: Node3D = g.bars
	var y := 5.0 if open else 0.0
	if instant:
		bars.position.y = y
		bars.visible = not open
	else:
		bars.visible = true
		var tw := create_tween()
		tw.tween_property(bars, "position:y", y, 1.2)
		if open:
			tw.tween_callback(func(): bars.visible = false)
	if nav_links.has(id):
		for l in nav_links[id]:
			(l as NavigationLink3D).enabled = open
	if nav_regions.has("door:" + id):
		(nav_regions["door:" + id] as NavigationRegion3D).enabled = open

# ---------------------------------------------------------------- the Depths (one sample floor)
func _depths() -> void:
	var D: Dictionary = world.depths
	var parent: Node3D = area_nodes["depths"]
	var mats: Dictionary = {}
	_wall_list(parent, D.walls, mats)
	# Stand-ins for the web's StairView (code-built there too): a worn stone disc with a faint glow (up = cold blue, down/chest = ember).
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = Color(0.18, 0.2, 0.26)
	disc_mat.emission_enabled = true
	disc_mat.emission = Color(0.2, 0.4, 0.8)
	disc_mat.emission_energy_multiplier = 0.45
	var down_mat := StandardMaterial3D.new()
	down_mat.albedo_color = Color(0.26, 0.18, 0.14)
	down_mat.emission_enabled = true
	down_mat.emission = Color(0.9, 0.4, 0.12)
	down_mat.emission_energy_multiplier = 0.45
	var marks := [[D.stairUp, disc_mat], [D.stairDown, down_mat]]
	if D.chest != null:
		marks.append([D.chest, down_mat])
	for m in marks:
		var cm := CylinderMesh.new()
		cm.top_radius = 0.8
		cm.bottom_radius = 0.8
		cm.height = 0.1
		var mi := MeshInstance3D.new()
		mi.mesh = cm
		mi.material_override = m[1]
		mi.position = Vector3(m[0].x, 0.06, m[0].z)
		parent.add_child(mi)
	# Everything drawn so far for the Depths is the sample floor: build_depths_floor hides it while a generated floor stands.
	_sample_depths_nodes = parent.get_children()

# ---------------------------------------------------------------- the generated Depths floor
var _sample_depths_nodes: Array = []
var _sample_lights: Array = []
var _depths_floor_root: Node3D = null
var _depths_gen_lights: Array = []
var _depths_stair_mat: StandardMaterial3D = null
var _depths_chest_mat: StandardMaterial3D = null

## Draw a generated floor (DmDepthsFloor.generate_floor Dictionary): room floors, door mouths, walls, props, the two stairs and the chest.
func build_depths_floor(f: Dictionary) -> void:
	_build_depths_floor_raw(f)
	if _depths_floor_root != null:
		apply_occlusion(_depths_floor_root)


func _build_depths_floor_raw(f: Dictionary) -> void:
	clear_depths_floor()
	var parent: Node3D = area_nodes["depths"]
	for n in _sample_depths_nodes:
		if is_instance_valid(n):
			(n as Node3D).visible = false
	_sample_lights = prop_lights.filter(func(e): return e.area == "depths")
	prop_lights = prop_lights.filter(func(e): return e.area != "depths")
	var root := Node3D.new()
	root.name = "DepthsFloor"
	parent.add_child(root)
	_depths_floor_root = root
	var theme: String = world.areas["depths"].theme
	for r in f["rooms"]:
		if r["active"]:
			var rc: Dictionary = r["rect"]
			_plane(root, rc.x0, rc.z0, rc.x1, rc.z1, theme, 0.02)
	for d in f["doors"]:
		var hx := 0.9 if absf(float(d.dir.x)) > 0.5 else 2.3
		var hz := 0.9 if absf(float(d.dir.z)) > 0.5 else 2.3
		_plane(root, d.x - hx, d.z - hz, d.x + hx, d.z + hz, theme, 0.02)
	# Walls: line segments with a thickness (DmDepthsFloor.wall_obstacle's box).
	var mats: Dictionary = {}
	var wl: Array = []
	for w in f["walls"]:
		var o := DmDepthsFloor.wall_obstacle(w)
		var ww: Dictionary = w.duplicate()
		ww["box"] = {"x0": o.x0, "z0": o.z0, "x1": o.x1, "z1": o.z1}
		var tex: String = String(w["texture"])
		var ref: Variant = null
		for sw in world.depths.walls:
			if sw.texture == tex:
				ref = sw
				break
		ww["color"] = ref.color if ref != null else 0x8a8070
		wl.append(ww)
	_wall_list(root, wl, mats, false)
	# Props (batched per kind, lights with the rest of the world's prop lights).
	var kinds: Dictionary = {}
	for p in f["props"]:
		if not world.propSpecs.has(p.prop):
			continue
		var q: Dictionary = p.duplicate()
		q["y"] = 0.0
		q["tilt"] = 0.0
		if not kinds.has(p.prop):
			kinds[p.prop] = []
		kinds[p.prop].append(q)
	var pool_pos: Array = []
	var before := prop_lights.size()
	for kind in kinds:
		var spec: Dictionary = world.propSpecs[kind]
		var plist: Array = kinds[kind]
		if spec.url != null:
			_prop_batch(root, spec, plist)
		if spec.has("light") and spec.light != null:
			for q in plist:
				_prop_light(root, q, spec.light, "depths")
				pool_pos.append({"x": q.x, "z": q.z, "y": float(spec.light.y) * float(q.scale), "L": spec.light})
	_light_pools(root, pool_pos, "depths")
	_depths_gen_lights = prop_lights.slice(before)
	# Stairs and chest: worn discs (the way up cold, the way down ember, sealed = dim), the chest a small box.
	var up_mat := StandardMaterial3D.new()
	up_mat.albedo_color = Color(0.18, 0.2, 0.26)
	up_mat.emission_enabled = true
	up_mat.emission = Color(0.2, 0.4, 0.8)
	up_mat.emission_energy_multiplier = 0.45
	_depths_stair_mat = StandardMaterial3D.new()
	_depths_stair_mat.albedo_color = Color(0.26, 0.18, 0.14)
	_depths_stair_mat.emission_enabled = true
	_depths_stair_mat.emission = Color(0.9, 0.4, 0.12)
	set_depths_stair_open(false)
	for m in [[f["stairUp"], up_mat], [f["stairDown"], _depths_stair_mat]]:
		var cm := CylinderMesh.new()
		cm.top_radius = 0.8
		cm.bottom_radius = 0.8
		cm.height = 0.1
		var mi := MeshInstance3D.new()
		mi.mesh = cm
		mi.material_override = m[1]
		mi.position = Vector3(m[0].x, 0.06, m[0].z)
		root.add_child(mi)
	if f["chest"] != null:
		_depths_chest_mat = StandardMaterial3D.new()
		_depths_chest_mat.albedo_color = Color(0.45, 0.3, 0.12)
		_depths_chest_mat.emission_enabled = true
		_depths_chest_mat.emission = Color(0.95, 0.8, 0.3)
		var bm := BoxMesh.new()
		bm.size = Vector3(1.1, 0.7, 0.7)
		var ci := MeshInstance3D.new()
		ci.name = "Chest"
		ci.mesh = bm
		ci.material_override = _depths_chest_mat
		ci.position = Vector3(f["chest"].x, 0.35, f["chest"].z)
		root.add_child(ci)
		set_depths_chest_opened(false)

func set_depths_stair_open(open: bool) -> void:
	if _depths_stair_mat != null:
		_depths_stair_mat.emission_energy_multiplier = 1.6 if open else 0.12

func set_depths_chest_opened(opened: bool) -> void:
	if _depths_chest_mat != null:
		_depths_chest_mat.emission_energy_multiplier = 0.0 if opened else 0.5

func clear_depths_floor() -> void:
	if _depths_floor_root != null and is_instance_valid(_depths_floor_root):
		_depths_floor_root.queue_free()
	_depths_floor_root = null
	for e in _depths_gen_lights:
		prop_lights.erase(e)
	_depths_gen_lights = []
	_depths_stair_mat = null
	_depths_chest_mat = null
	if not _sample_lights.is_empty():
		prop_lights.append_array(_sample_lights)
		_sample_lights = []
	for n in _sample_depths_nodes:
		if is_instance_valid(n):
			(n as Node3D).visible = true

# ---------------------------------------------------------------- NPCs
## false when DmNpcViews (game/) animates the people instead.
var npcs_enabled := true

func _npcs() -> void:
	if not npcs_enabled:
		return
	var nd: Dictionary = DmData.load_json("npcs")
	for n in world.npcs:
		var entry: Dictionary = nd.models[n.model]
		var c := DmModels.creature_from(entry)
		var root: Node3D = c.root
		root.position = Vector3(n.x, 0, n.z)
		root.rotation.y = n.rest
		area_nodes[n.area].add_child(root)
		(c.animator as DmAnimator).loco(0.0)

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

func _near(r: Dictionary, x0: float, z0: float, x1: float, z1: float, pad: float) -> bool:
	return x1 > r.x0 - pad and x0 < r.x1 + pad and z1 > r.z0 - pad and z0 < r.z1 + pad

func _nav_mesh() -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.agent_radius = 0.5
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.agent_max_slope = 45.0
	nm.region_min_size = 1.0
	return nm

func _all_obstacles() -> Array:
	# {kind, x0,z0,x1,z1 (aabb), poly}
	var out: Array = []
	for w in world.walls:
		var b: Dictionary = _nbox(w.box)
		out.append({"x0": b.x0, "z0": b.z0, "x1": b.x1, "z1": b.z1, "poly": _outline_box(b.x0, b.z0, b.x1, b.z1)})
	for w in world.depths.walls:
		var b2: Dictionary = _nbox(w.box)
		out.append({"x0": b2.x0, "z0": b2.z0, "x1": b2.x1, "z1": b2.z1, "poly": _outline_box(b2.x0, b2.z0, b2.x1, b2.z1)})
	var plist: Array = world.props.duplicate()
	plist.append_array(world.depths.props)
	for p in plist:
		var o: Variant = p.obstacle
		if o == null:
			continue
		if o.kind == "circle":
			out.append({"x0": o.x - o.r - GROW, "z0": o.z - o.r - GROW, "x1": o.x + o.r + GROW, "z1": o.z + o.r + GROW, "poly": _outline_circle(o.x, o.z, o.r + GROW)})
		else:
			out.append({"x0": o.x0 - GROW, "z0": o.z0 - GROW, "x1": o.x1 + GROW, "z1": o.z1 + GROW, "poly": _outline_box(o.x0 - GROW, o.z0 - GROW, o.x1 + GROW, o.z1 + GROW)})
	for n in world.nodes:
		if float(n.collider) > 0.0:
			var r: float = float(n.collider) + GROW
			out.append({"x0": n.x - r, "z0": n.z - r, "x1": n.x + r, "z1": n.z + r, "poly": _outline_circle(n.x, n.z, r)})
	for pd in world.ponds:
		out.append({"x0": pd.x0 - GROW, "z0": pd.z0 - GROW, "x1": pd.x1 + GROW, "z1": pd.z1 + GROW, "poly": _outline_box(pd.x0 - GROW, pd.z0 - GROW, pd.x1 + GROW, pd.z1 + GROW)})
	return out

func _bake_region(key: String, faces: PackedVector3Array, rect: Dictionary, obstacles: Array) -> void:
	var src := NavigationMeshSourceGeometryData3D.new()
	src.add_faces(faces, Transform3D.IDENTITY)
	for o in obstacles:
		if _near(rect, o.x0, o.z0, o.x1, o.z1, 1.5):
			src.add_projected_obstruction(o.poly, -0.5, 3.0, true)
	var nm := _nav_mesh()
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	var reg := NavigationRegion3D.new()
	reg.name = key.replace(":", "_")
	reg.navigation_mesh = nm
	add_child(reg)
	nav_regions[key] = reg

func _bake_nav() -> void:
	var t0 := Time.get_ticks_msec()
	var obstacles := _all_obstacles()
	for id in world.order:
		var a: Dictionary = world.areas[id]
		if id == "depths":
			var faces := PackedVector3Array()
			for r in world.depths.rooms:
				if r.active:
					faces.append_array(_quad_faces(r.rect))
			for dd in world.depths.doors:
				var hx := 0.9 if absf(float(dd.dir.x)) > 0.5 else 2.3
				var hz := 0.9 if absf(float(dd.dir.z)) > 0.5 else 2.3
				faces.append_array(_quad_faces({"x0": dd.x - hx, "z0": dd.z - hz, "x1": dd.x + hx, "z1": dd.z + hz}))
			_bake_region("area:depths", faces, a.rect, obstacles)
		else:
			_bake_region("area:" + id, _quad_faces(a.rect), a.rect, obstacles)
	for d in world.doors:
		_bake_region("door:" + d.id, _quad_faces(d.rect), d.rect, obstacles)
		# Links join the corridor region to each room across the one-metre overlap (both ends sit inside both regions' eroded edges).
		var links: Array = []
		for room_id in [d.a, d.b]:
			var rr: Dictionary = world.areas[room_id].rect
			var inside: Vector3
			var outside: Vector3
			if d.axis == "z":
				var low: bool = absf(d.rect.z0 - rr.z1) < 1.2   # the room lies at lower z than the corridor
				var edge: float = rr.z1 if low else rr.z0
				var sg := -1.0 if low else 1.0
				inside = Vector3(d.cx, 0, edge + sg * 0.6)
				outside = Vector3(d.cx, 0, edge + sg * 0.4)
			else:
				var low_x: bool = absf(d.rect.x0 - rr.x1) < 1.2
				var edge_x: float = rr.x1 if low_x else rr.x0
				var sgx := -1.0 if low_x else 1.0
				inside = Vector3(edge_x + sgx * 0.6, 0, d.cz)
				outside = Vector3(edge_x + sgx * 0.4, 0, d.cz)
			var link := NavigationLink3D.new()
			link.bidirectional = true
			link.start_position = inside
			link.end_position = outside
			link.navigation_layers = 1
			add_child(link)
			links.append(link)
		nav_links[d.id] = links
	nav_bake_ms = Time.get_ticks_msec() - t0

func _apply_unlock_state() -> void:
	for id in world.order:
		var on: bool = unlocked.has(id) or (id == "depths" and depths_open)
		(nav_regions["area:" + id] as NavigationRegion3D).enabled = on
	for d in world.doors:
		var open: bool = _is_unlocked(d.a) and _is_unlocked(d.b)
		if d.id == "chapter_graves":
			open = true
			(nav_regions["door:" + d.id] as NavigationRegion3D).enabled = true
			for l in nav_links[d.id]:
				(l as NavigationLink3D).enabled = true
		else:
			set_door_open(d.id, open, true)

func _is_unlocked(id: String) -> bool:
	return unlocked.has(id) or (id == "depths" and depths_open)

## Seals: `areas` = the area ids whose seal is broken (always-open halls stay open). The Depths are an instance, opened by a run (`open_instance`).
func set_unlocked(areas: Array) -> void:
	unlocked.clear()
	for id in world.order:
		var a: Dictionary = world.areas[id]
		if (not a.unlock and not a.instance) or areas.has(id):
			if not a.instance:
				unlocked[id] = true
	_apply_unlock_state()

func open_instance(id: String, open: bool) -> void:
	if id == "depths":
		depths_open = open
		_apply_unlock_state()

func open_all() -> void:
	var all: Array = []
	for id in world.order:
		all.append(id)
	set_unlocked(all)
	open_instance("depths", true)

func nav_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	return NavigationServer3D.map_get_path(get_world_3d().navigation_map, from, to, true)

func nav_closest(p: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, p)
