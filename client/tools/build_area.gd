extends SceneTree
## Builds an area scene (client/areas/<id>.tscn) from data/slice/world.json: the layout DmWorldBuilder (world/world_builder.gd) builds at runtime,
## written once, offline, with a baked navigation mesh, occluders and visibility ranges. One converter for every area.
##
##   godot --headless --path client --script res://tools/build_area.gd -- graves [more area ids] [--world=<file>] [--out=res://areas] [--lenient]
##
## Normally run through tools/rebuild/build-areas.sh (it imports first). Output, all deterministic:
##   <out>/<id>.tscn            the area
##   <out>/props/<model>.tscn   one prefab per prop or gathering-node model (the glTF, normalised to its height; small props get a visibility range)
##   res://areas/common/ring.png, glow.png   the two generated decal textures (DmWorldBuilder draws them at start-up)
## `--lenient` skips models whose files are not in client/assets instead of failing (smoke runs).
## Exit codes: 0 done, 1 failed, 3 wrote a generated texture that needs an import first (build-areas.sh imports and runs again).

const DEFAULT_WORLD := "data/slice/world.json"
const DEFAULT_OUT := "res://areas"
const COMMON_DIR := "res://areas/common"   # the generated decal textures, shared by every area (and by scratch runs with another --out)
const ASSET_BASE := "res://assets/slice/"
const TEX := ASSET_BASE + "art/textures/%s.webp"
## Ground and wall textures are seen at grazing angles (world_builder.SHARP).
const SHARP := BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

## Values from world_builder.gd.
const POINT_K := 0.18       # prop light energy = intensity x POINT_K
const GROW := 0.55          # navmesh obstruction grow for props, nodes and ponds
const NAV_PAD := 1.5        # an obstruction is baked into a region when it lies within this many metres of the region's rect
const FLOOR_OUTSET := 0.8   # an area's ground extends this far past its rect
const RING_PX := 256

## Choices of this converter (client/tests/areas.gd reads the same constants).
const SMALL_PROP_MAX_HEIGHT := 1.5     # props up to this tall: no shadow (as in world_builder) and a visibility range
const SMALL_PROP_VISIBLE_END := 70.0   # metres; the camera never sees further than about 60 (zoomed out on an ultrawide)
const OCC_WALL_MIN_HEIGHT := 3.0       # walls this tall and this long get a box occluder
const OCC_WALL_MIN_LENGTH := 4.0
const OCC_PROP_MIN_HEIGHT := 3.0       # solid box-collider props at least this tall and wide get one (the mausoleums)
const OCC_PROP_MIN_SIDE := 3.0
const OCC_PROP_SHRINK := 0.7           # occluders are the collider box scaled down so they never hide what is visible past a prop
## The lightmap density of every floor quad (the ground, the paths, the door corridors), in metres a texel. A quad built by hand has no size hint, so Godot gives it a lightmap of 64 x 64
## texels whatever its size (the Chapterhouse's ground 0.43 m a texel, the Graves' 0.84 x 0.65 m, a 40 m path 0.6 m): a candle's pool 0.7 to 1 m above the floor came out at a quarter of the
## real-time light. 0.125 m (8 texels a metre, the door corridors' old density) keeps a pool's shape; no floor is over 440 texels a side, far under the bake's 4096 limit.
const FLOOR_TEXEL := 0.125

var world: Dictionary
var out_dir := DEFAULT_OUT
var lenient := false
var errors: PackedStringArray = []
var skipped_models: Dictionary = {}

var area_root: Node3D
var area_id := ""
var rect: Dictionary

var _tex_cache: Dictionary = {}
var _res_cache: Dictionary = {}       # materials, meshes, shapes shared inside one area, by key
var _models: Dictionary = {}          # "url@height" -> {path, norm}
var _variants: Dictionary = {}        # url -> distinct heights over the whole world
var _ring_tex: Texture2D
var _glow_tex: Texture2D
var _colliders: StaticBody3D
var _nav: Node3D


func _init() -> void:
	var ids: PackedStringArray = []
	var world_path := DEFAULT_WORLD
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--world="):
			world_path = a.substr(8)
		elif a.begins_with("--out="):
			out_dir = a.substr(6).trim_suffix("/")
		elif a == "--lenient":
			lenient = true
		elif not a.begins_with("--"):
			ids.append(a)
	if ids.is_empty():
		_fail("usage: build_area.gd -- <area id> [more ids] [--world=<file>] [--out=res://areas] [--lenient]")
		return
	var wp := world_path if world_path.is_absolute_path() else ProjectSettings.globalize_path("res://").path_join(world_path)
	var text := FileAccess.get_file_as_string(wp)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		_fail("cannot read the world data: %s" % wp)
		return
	world = parsed
	_scan_model_heights()
	if not _ensure_common_textures():
		print("build_area: wrote generated textures; import the project, then run again")
		quit(3)
		return
	for id in ids:
		if not world.areas.has(id):
			_fail("unknown area '%s' (known: %s)" % [id, ", ".join(world.order)])
			return
		if world.areas[id].instance:
			_fail("area '%s' is generated at runtime (the Depths' floors), not converted" % id)
			return
	for id in ids:
		_build(id)
	if not errors.is_empty():
		for e in errors:
			printerr("build_area: ", e)
		quit(1)
		return
	if not skipped_models.is_empty():
		print("build_area: --lenient skipped %d model(s) missing from client/assets: %s" % [skipped_models.size(), ", ".join(skipped_models.keys())])
	quit(0)


func _fail(msg: String) -> void:
	printerr("build_area: ", msg)
	quit(1)


# ---------------------------------------------------------------- shared helpers
func _hex(v: Variant) -> Color:
	return Color.hex(int(v) * 256 + 255)


func _tex(name: String) -> Texture2D:
	if not _tex_cache.has(name):
		var path := TEX % name
		if not ResourceLoader.exists(path):
			errors.append("texture missing: %s (add it to client/assets)" % path)
			_tex_cache[name] = null
		else:
			_tex_cache[name] = load(path)
	return _tex_cache[name]


## A node under `parent`, owned by the scene root so it is saved.
func _add(parent: Node, node: Node, name: String) -> Node:
	node.name = name
	parent.add_child(node)
	node.owner = area_root
	return node


func _group(parent: Node, name: String) -> Node3D:
	return _add(parent, Node3D.new(), name) as Node3D


## Resources shared between nodes of one area, built once per key.
func _shared(key: String, make: Callable) -> Variant:
	if not _res_cache.has(key):
		_res_cache[key] = make.call()
	return _res_cache[key]


func _area_of_point(x: float, z: float) -> String:
	for id: String in world.order:
		var r: Dictionary = world.areas[id].rect
		if x >= r.x0 and x <= r.x1 and z >= r.z0 and z <= r.z1:
			return id
	return ""


func _area_of_rect(r: Dictionary) -> String:
	return _area_of_point((float(r.x0) + float(r.x1)) / 2.0, (float(r.z0) + float(r.z1)) / 2.0)


func _nbox(b: Dictionary) -> Dictionary:
	return {"x0": minf(b.x0, b.x1), "x1": maxf(b.x0, b.x1), "z0": minf(b.z0, b.z1), "z1": maxf(b.z0, b.z1)}


# ---------------------------------------------------------------- generated decal textures
## The two textures DmWorldBuilder draws at start-up (`_ring_texture` / `_glow_texture`), written as PNGs next to the areas.
func _ensure_common_textures() -> bool:
	var dir := COMMON_DIR
	DirAccess.make_dir_recursive_absolute(dir)
	var ring := Image.create(RING_PX, RING_PX, false, Image.FORMAT_RGBA8)
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
			ring.set_pixel(x, y, Color(1, 1, 1, a))
	var glow := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d2 := Vector2(x - 31.5, y - 31.5).length() / 31.5
			var a2 := clampf(1.0 - d2, 0.0, 1.0)
			a2 = a2 * a2 * (3.0 - 2.0 * a2)
			glow.set_pixel(x, y, Color(1, 1, 1, a2))
	var wrote := false
	for pair in [["ring", ring], ["glow", glow]]:
		var path: String = dir.path_join(pair[0] + ".png")
		var img: Image = pair[1]
		var old := Image.load_from_file(ProjectSettings.globalize_path(path)) if FileAccess.file_exists(path) else null
		if old == null or old.get_data() != img.get_data():
			img.save_png(path)
			wrote = true
		# Lossless with mipmaps (thin sigil lines shimmer without them); Godot completes the file on import.
		var imp := path + ".import"
		if not FileAccess.file_exists(imp):
			var f := FileAccess.open(imp, FileAccess.WRITE)
			f.store_string("[remap]\n\nimporter=\"texture\"\ntype=\"CompressedTexture2D\"\n\n[params]\n\ncompress/mode=0\nmipmaps/generate=true\n")
			f.close()
			wrote = true
	if wrote:
		return false
	_ring_tex = load(dir.path_join("ring.png"))
	_glow_tex = load(dir.path_join("glow.png"))
	if _ring_tex == null or _glow_tex == null:
		errors.append("the generated decal textures are not imported yet")
		return false
	return true


# ---------------------------------------------------------------- prop and node models (prefab scenes)
func _scan_model_heights() -> void:
	var add := func(url: String, h: float) -> void:
		if not _variants.has(url):
			_variants[url] = []
		if not (_variants[url] as Array).has(h):
			(_variants[url] as Array).append(h)
	for kind: String in world.propSpecs:
		var spec: Dictionary = world.propSpecs[kind]
		if spec.url != null:
			add.call(spec.url, float(spec.height))
	for n: Dictionary in world.nodes:
		if n.model != null:
			add.call(n.model, float(n.modelHeight))


func _model_name(url: String, height: float) -> String:
	var base := url.get_file().get_basename()
	return base if (_variants[url] as Array).size() == 1 else "%s_h%d" % [base, roundi(height * 100.0)]


## DmModels.analyze: the transform that stands a glTF on the ground, centred on x/z, scaled to `height`. Returns {path, norm} or {} (lenient, missing).
func _model(url: String, height: float, is_prop: bool) -> Dictionary:
	var key := "%s@%s" % [url, height]
	if _models.has(key):
		return _models[key]
	var glb := ASSET_BASE + url
	if not ResourceLoader.exists(glb):
		if lenient:
			skipped_models[url] = true
		else:
			errors.append("model missing: %s (add it to client/assets)" % glb)
		_models[key] = {}
		return {}
	var ps: PackedScene = load(glb)
	var tmp: Node3D = ps.instantiate()
	var bb := AABB()
	var first := true
	for n in tmp.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var cur: Node = mi
		while cur != null and cur != tmp:
			if cur is Node3D:
				xf = (cur as Node3D).transform * xf
			cur = cur.get_parent()
		var box: AABB = xf * mi.mesh.get_aabb()
		bb = box if first else bb.merge(box)
		first = false
	tmp.free()
	var s := height / maxf(bb.size.y, 0.0001)
	var c := bb.get_center()
	var norm := Transform3D(Basis.from_scale(Vector3.ONE * s), Vector3(-c.x * s, -bb.position.y * s, -c.z * s))
	# The prefab: the glTF instanced with the normalising transform; small props lose their shadow and get a visibility range.
	var name := _model_name(url, height)
	var small := is_prop and height <= SMALL_PROP_MAX_HEIGHT
	var holder := Node3D.new()
	holder.name = name
	holder.set_meta("model", url)
	holder.set_meta("height", height)
	holder.set_meta("small", small)
	var inst := ps.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
	inst.name = "model"
	inst.transform = norm
	holder.add_child(inst)
	inst.owner = holder
	holder.set_editable_instance(inst, true)
	if small:
		# Overrides inside the instanced glTF are saved because the nodes keep the instance as their owner.
		for n in inst.find_children("*", "MeshInstance3D", true, false):
			var mi2 := n as MeshInstance3D
			mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi2.visibility_range_end = SMALL_PROP_VISIBLE_END
	var path := out_dir.path_join("props").path_join(name + ".tscn")
	_save_scene(holder, path)
	holder.free()
	# Instances must come from the file (a scene that knows its path), or the area would copy the nodes instead of referencing the prefab.
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	var info := {"path": path, "norm": norm, "packed": packed}
	_models[key] = info
	return info


# ---------------------------------------------------------------- saving
## Packs and saves a scene, then rewrites the ids Godot randomises on every save so regenerating changes nothing. Returns the packed scene.
func _save_scene(scene_root: Node, path: String) -> PackedScene:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var packed := PackedScene.new()
	var err := packed.pack(scene_root)
	if err != OK:
		errors.append("cannot pack %s (error %d)" % [path, err])
		return packed
	err = ResourceSaver.save(packed, path, ResourceSaver.FLAG_CHANGE_PATH)
	if err != OK:
		errors.append("cannot save %s (error %d)" % [path, err])
		return packed
	_stabilise_ids(path)
	return packed


func _stabilise_ids(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var lines := text.split("\n")
	var map: Dictionary = {}
	var counters: Dictionary = {}
	var ext_re := RegEx.create_from_string("^\\[ext_resource .*path=\"([^\"]+)\".* id=\"([^\"]+)\"")
	var sub_re := RegEx.create_from_string("^\\[sub_resource type=\"([^\"]+)\" id=\"([^\"]+)\"")
	var node_re := RegEx.create_from_string("^\\[node name=\"([^\"]+)\"(?: type=\"[^\"]+\")?(?: parent=\"([^\"]*)\")?(?: index=\"\\d+\")? unique_id=(\\d+)")
	var ext_n := 0
	var used: Dictionary = {}
	for i in lines.size():
		var line := lines[i]
		var m := ext_re.search(line)
		if m != null:
			ext_n += 1
			map[m.get_string(2)] = "%d_%s" % [ext_n, m.get_string(1).md5_text().substr(0, 5)]
			continue
		m = sub_re.search(line)
		if m != null:
			var t := m.get_string(1)
			counters[t] = int(counters.get(t, 0)) + 1
			map[m.get_string(2)] = "%s_%s" % [t, ("%s%d" % [t, counters[t]]).md5_text().substr(0, 5)]
			continue
		# Nodes this scene owns get an id derived from their path. Overrides inside an instanced glTF (index=) lose theirs: the glTF importer
		# draws that node's id at random on every import, and Godot finds the node by its path without it.
		m = node_re.search(line)
		if m != null and line.contains(" index=\""):
			lines[i] = line.replace(" unique_id=" + m.get_string(3), "")
		elif m != null:
			var parent := m.get_string(2)
			var full := m.get_string(1) if parent.is_empty() else (m.get_string(1) if parent == "." else "%s/%s" % [parent, m.get_string(1)])
			var uid := ("%s|%s" % [path, full]).md5_text().substr(0, 7).hex_to_int() & 0x3fffffff
			while used.has(uid):
				uid += 1
			used[uid] = true
			lines[i] = line.replace("unique_id=" + m.get_string(3), "unique_id=%d" % uid)
	text = "\n".join(lines)
	for old: String in map:
		text = text.replace("\"%s\"" % old, "\"%s\"" % map[old])
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ---------------------------------------------------------------- the area
func _build(id: String) -> void:
	area_id = id
	var a: Dictionary = world.areas[id]
	rect = a.rect
	_res_cache.clear()
	area_root = Node3D.new()
	area_root.name = id
	area_root.set_meta("area_id", id)
	area_root.set_meta("area_name", a.name)
	area_root.set_meta("theme", a.theme)
	area_root.set_meta("safe", a.safe)
	area_root.set_meta("rect", [rect.x0, rect.z0, rect.x1, rect.z1])
	var floors_n := _group(area_root, "Floor")
	var walls_n := _group(area_root, "Walls")
	var props_n := _group(area_root, "Props")
	var nodes_n := _group(area_root, "GatherNodes")
	var decals_n := _group(area_root, "Decals")
	var doors_n := _group(area_root, "Doors")
	var lights_n := _group(area_root, "Lights")
	var occ_n := _group(area_root, "Occluders")
	_colliders = _add(area_root, StaticBody3D.new(), "Colliders") as StaticBody3D
	_nav = _group(area_root, "Navigation")

	_floors(floors_n)
	_walls(walls_n, occ_n)
	_props(props_n, lights_n, occ_n)
	_gather_nodes(nodes_n)
	_decals(decals_n)
	_water()
	_doors(doors_n)
	_lightmap(area_root)
	_bake_nav()

	var path := out_dir.path_join(id + ".tscn")
	_save_scene(area_root, path)
	area_root.free()
	print("build_area: %s -> %s" % [id, path])


# ---------------------------------------------------------------- the lighting bake (client/addons/dm_bake/README.md)
## The area's LightmapGI. What is baked: the prop lights (bake mode Static: direct and bounced light) and the area's ambient, which a lightmapped
## surface takes from its lightmap instead of the environment, so the bake carries the same plain-colour hemisphere ambient DmWorldBuilder.set_area
## gives the area at runtime (same constants, the area's hemisphere factor included: the Acre's and the Wing's are brighter). The Environment's
## ambient colour is an sRGB colour, which the renderer converts to linear light; the bake takes `environment_custom_color` as it is, so it gets
## the converted colour. The moon and the rim light stay real-time (they live in the game scene, outside this subtree; the Acre's and the
## Wing's brighter moon is `DmWorldBuilder.set_area`'s). A bake made for this scene is picked up when `<id>.lmbake` sits next to it; a bake belongs
## to the scene it was made from.
func _lightmap(parent: Node3D) -> void:
	var lm := LightmapGI.new()
	lm.quality = LightmapGI.BAKE_QUALITY_MEDIUM
	lm.bounces = 3
	lm.directional = false
	lm.use_denoiser = true
	lm.max_texture_size = 4096
	lm.environment_mode = LightmapGI.ENVIRONMENT_MODE_CUSTOM_COLOR
	lm.environment_custom_color = _area_ambient(world.areas[area_id]).srgb_to_linear()
	lm.environment_custom_energy = float(world.lighting.hemiIntensity) * DmWorldBuilder.HEMI_K * float(DmWorldBuilder.AREA_HEMI_K.get(area_id, 1.0))
	var data := out_dir.path_join(area_id + ".lmbake")
	if ResourceLoader.exists(data):
		lm.light_data = load(data)
	_add(parent, lm, "Lightmap")


## DmWorldBuilder.set_area's ambient colour for an area (the hemisphere sky lifted to a floor, mixed with the lifted ground).
func _area_ambient(a: Dictionary) -> Color:
	var amb: Dictionary = a.ambient
	var sky := Color.html(amb.hemiSky)
	var peak := maxf(sky.r, maxf(sky.g, sky.b))
	if peak > 0.01:
		var luma := 0.2126 * sky.r + 0.7152 * sky.g + 0.0722 * sky.b
		var boost := clampf(maxf(DmWorldBuilder.AMBIENT_FLOOR / peak, DmWorldBuilder.AMBIENT_LUMA_FLOOR / maxf(luma, 0.01)), 1.0, DmWorldBuilder.AMBIENT_MAX_BOOST)
		sky = Color(sky.r * boost, sky.g * boost, sky.b * boost)
	var gnd := Color.html(amb.hemiGround).lerp(sky, DmWorldBuilder.GROUND_LIFT)
	return sky.lerp(gnd, DmWorldBuilder.AMBIENT_GROUND_MIX)


# ---------------------------------------------------------------- floors
func _theme_mat(theme_key: String) -> StandardMaterial3D:
	return _shared("floor:" + theme_key, func() -> StandardMaterial3D:
		var f: Dictionary = world.floors[theme_key]
		var m := StandardMaterial3D.new()
		m.albedo_texture = _tex(f.tex)
		m.texture_filter = SHARP
		m.albedo_color = DmCompatAlbedo.tint(String(f.tex), _hex(f.color))   # the old game's albedo: client/next/look/dm_compat_albedo.gd
		m.roughness = float(f.rough)
		if f.has("glow"):
			m.emission_enabled = true
			m.emission = _hex(f.glow)
			m.emission_texture = _tex(f.tex)
			m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		return m)


## One ground quad. UVs are world-anchored (the web sets them from world position), so neighbouring quads of one theme line up; UV2 fills 0..1 for lightmaps.
func _ground(parent: Node3D, name: String, x0: float, z0: float, x1: float, z1: float, theme_key: String, y: float) -> MeshInstance3D:
	var t := float(world.floors[theme_key].tile)
	var cx := (x0 + x1) / 2.0
	var cz := (z0 + z1) / 2.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)]
	for c: Vector2 in corners:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(c.x / t, c.y / t))
		st.set_uv2(Vector2((c.x - x0) / (x1 - x0), (c.y - z0) / (z1 - z0)))
		st.add_vertex(Vector3(c.x - cx, 0.0, c.y - cz))
	for i in [0, 1, 2, 0, 2, 3]:
		st.add_index(i)
	st.generate_tangents()
	var mesh := st.commit()
	mesh.lightmap_size_hint = Vector2i(ceili((x1 - x0) / FLOOR_TEXEL), ceili((z1 - z0) / FLOOR_TEXEL))   # the bake's lightmap for this quad: FLOOR_TEXEL
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _theme_mat(theme_key)
	mi.position = Vector3(cx, y, cz)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return _add(parent, mi, name) as MeshInstance3D


func _floors(parent: Node3D) -> void:
	var a: Dictionary = world.areas[area_id]
	_ground(parent, "ground", rect.x0 - FLOOR_OUTSET, rect.z0 - FLOOR_OUTSET, rect.x1 + FLOOR_OUTSET, rect.z1 + FLOOR_OUTSET, a.theme, 0.0)
	for i in world.paths.size():
		var p: Dictionary = world.paths[i]
		if _area_of_rect(p) == area_id:
			_ground(parent, "path_%02d" % i, p.x0, p.z0, p.x1, p.z1, "nave", 0.008)
	# The wing's rugs and the fen's hummocks are floor dressing of their area.
	if area_id == "alchemist_wing":
		_wing_floor(parent)
	if area_id == "fen":
		_hummocks(parent)


# ---------------------------------------------------------------- walls + colliders
func _body(pos: Vector3, shape: Shape3D, name: String) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = pos
	return _add(_colliders, cs, name) as CollisionShape3D


func _box_shape(size: Vector3) -> BoxShape3D:
	return _shared("box:%s" % size, func() -> BoxShape3D:
		var bs := BoxShape3D.new()
		bs.size = size
		return bs)


func _cyl_shape(r: float, h: float) -> CylinderShape3D:
	return _shared("cyl:%s:%s" % [r, h], func() -> CylinderShape3D:
		var cs := CylinderShape3D.new()
		cs.radius = r
		cs.height = h
		return cs)


func _wall_mat(w: Dictionary) -> StandardMaterial3D:
	return _shared("wall:" + String(w.texture), func() -> StandardMaterial3D:
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = _tex(w.texture)
		mat.texture_filter = SHARP
		mat.albedo_color = DmCompatAlbedo.tint(String(w.texture), _hex(w.color))
		mat.roughness = 0.92
		mat.uv1_triplanar = true
		mat.uv1_world_triplanar = true
		mat.uv1_scale = Vector3.ONE / 4.0
		return mat)


func _walls(parent: Node3D, occ: Node3D) -> void:
	var n := 0
	for w: Dictionary in world.walls:
		if w.area != area_id:
			continue
		var b := _nbox(w.box)
		var sx: float = b.x1 - b.x0
		var sz: float = b.z1 - b.z0
		var h: float = w.height
		var bm := BoxMesh.new()
		bm.size = Vector3(sx, h, sz)
		bm.add_uv2 = true   # lightmap UVs for the later bake
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.material_override = _wall_mat(w)
		mi.position = Vector3((b.x0 + b.x1) / 2.0, h / 2.0, (b.z0 + b.z1) / 2.0)
		_add(parent, mi, "wall_%03d" % n)
		var ch := maxf(h, 3.0)
		_body(Vector3(mi.position.x, ch / 2.0, mi.position.z), _box_shape(Vector3(sx, ch, sz)), "wall_%03d" % n)
		if h >= OCC_WALL_MIN_HEIGHT and maxf(sx, sz) >= OCC_WALL_MIN_LENGTH:
			var oi := OccluderInstance3D.new()
			var bo := BoxOccluder3D.new()
			bo.size = Vector3(sx, h, sz)
			oi.occluder = bo
			oi.position = mi.position
			_add(occ, oi, "wall_%03d" % n)
		n += 1


# ---------------------------------------------------------------- props
func _props(parent: Node3D, lights: Node3D, occ: Node3D) -> void:
	var counts: Dictionary = {}
	var pool_pos: Array = []
	for p: Dictionary in world.props:
		if p.area != area_id:
			continue
		var kind: String = p.prop
		var spec: Dictionary = world.propSpecs[kind]
		var idx: int = counts.get(kind, 0)
		counts[kind] = idx + 1
		var label := "%s_%03d" % [kind, idx]
		var o: Variant = p.obstacle
		if o != null:
			if o.kind == "circle":
				_body(Vector3(o.x, 1.5, o.z), _cyl_shape(o.r, 3.0), label)
			else:
				_body(Vector3((o.x0 + o.x1) / 2.0, 1.5, (o.z0 + o.z1) / 2.0), _box_shape(Vector3(o.x1 - o.x0, 3.0, o.z1 - o.z0)), label)
		if spec.url != null:
			var m := _model(spec.url, float(spec.height), true)
			if not m.is_empty():
				var tilt: float = p.tilt
				var basis := Basis.from_euler(Vector3(tilt, p.rot, tilt * 0.6), EULER_ORDER_XYZ) * Basis.from_scale(Vector3.ONE * float(p.scale))
				var inst := (m.packed as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
				inst.transform = Transform3D(basis, Vector3(p.x, p.y, p.z))
				inst.set_meta("prop_kind", kind)
				_add(parent, inst, label)
		if spec.has("light") and spec.light != null:
			_prop_light(lights, p, spec.light, label)
			pool_pos.append({"x": p.x, "z": p.z, "L": spec.light})
		_prop_occluder(occ, p, spec, label)
	_light_pools(lights, pool_pos)


## Solid box-collider props that are big enough to hide things behind them (the mausoleums) get an occluder: the collider box, rotated
## like the prop, scaled down, standing on the ground.
func _prop_occluder(occ: Node3D, p: Dictionary, spec: Dictionary, label: String) -> void:
	var c: Variant = spec.get("collider")
	if c == null or c.kind != "box":
		return
	var s := float(p.scale)
	var h := float(spec.height) * s
	if h < OCC_PROP_MIN_HEIGHT or minf(float(c.hw), float(c.hd)) * 2.0 * s < OCC_PROP_MIN_SIDE:
		return
	var oi := OccluderInstance3D.new()
	var bo := BoxOccluder3D.new()
	bo.size = Vector3(float(c.hw) * 2.0 * s, h, float(c.hd) * 2.0 * s) * OCC_PROP_SHRINK
	oi.occluder = bo
	oi.transform = Transform3D(Basis(Vector3.UP, float(p.rot)), Vector3(p.x, float(p.y) + bo.size.y / 2.0, p.z))
	_add(occ, oi, label)


func _prop_light(parent: Node3D, p: Dictionary, L: Dictionary, label: String) -> void:
	var col := _hex(L.color)
	var light := OmniLight3D.new()
	light.light_color = col
	light.omni_range = float(L.distance)
	light.light_energy = float(L.intensity) * POINT_K
	light.omni_attenuation = 1.3
	light.light_bake_mode = Light3D.BAKE_STATIC   # placeholder for the lighting bake; still lights dynamic objects
	light.position = Vector3(p.x, float(L.y) * float(p.scale) + float(p.y), p.z)
	light.set_meta("prop_kind", p.prop)
	_add(parent, light, label)
	# The flame itself is not here: the web draws point sprites and the world dressing draws them at the wicks (DmWfxFlames: client/world_fx/README.md "World dressing").


## Floor light pools under every flame (WorldView.buildPools): one vertex-coloured additive mesh per area.
func _light_pools(parent: Node3D, srcs: Array) -> void:
	if srcs.is_empty():
		return
	var tone := {"gain": 1.0, "scale": 1.0}
	if area_id == "nave":
		tone = {"gain": 0.68, "scale": 0.8}
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s: Dictionary in srcs:
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
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true   # the Compatibility renderer reads every vertex colour as sRGB, Forward+ as linear (the pools came out 9 times too bright): "Graphics presets" in client/next/perf/README.md
	m.albedo_texture = _glow_tex
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_add(parent, mi, "light_pools")


# ---------------------------------------------------------------- gathering nodes
func _gather_nodes(parent: Node3D) -> void:
	for n: Dictionary in world.nodes:
		if n.area != area_id:
			continue
		var holder := Node3D.new()
		holder.position = Vector3(n.x, 0.04, n.z)
		holder.rotation.y = n.rot
		holder.set_meta("node_id", n.id)
		holder.set_meta("node_type", n.type)
		holder.set_meta("node_kind", n.kind)
		_add(parent, holder, String(n.id))
		if n.model != null:
			var m := _model(n.model, float(n.modelHeight), false)
			if not m.is_empty():
				var inst := (m.packed as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
				_add(holder, inst, "model")
			if n.kind == "seam" or n.kind == "geode":
				_ore_crystals(holder, n)
		else:
			_node_standin(holder, n)
		var cs: float = float(n.collider)
		if cs > 0.0:
			_body(Vector3(n.x, 1.5, n.z), _cyl_shape(cs, 3.0), String(n.id))


## Ore tint: a small emissive crystal overlay (the web keeps the vein colour out of the baked model).
func _ore_crystals(holder: Node3D, n: Dictionary) -> void:
	var tint := Color.html(n.tint)
	var vm := StandardMaterial3D.new()
	vm.albedo_color = tint
	vm.emission_enabled = true
	vm.emission = tint
	vm.emission_energy_multiplier = 0.9 if n.kind == "geode" else 0.55
	var bm := BoxMesh.new()
	bm.add_uv2 = true   # static for the bake: lightmap UVs
	bm.size = Vector3(0.12, 0.34, 0.12)
	var k := 0
	for sh in [[0.2, 0.5, 0.45], [-0.25, 0.45, 0.42], [0.45, 0.35, 0.3]]:
		var vi := MeshInstance3D.new()
		vi.mesh = bm
		vi.material_override = vm
		vi.position = Vector3(sh[0], sh[1] * 0.6, sh[2] * 0.4)
		vi.rotation = Vector3(0.3, sh[0] * 3.0, sh[0])
		_add(holder, vi, "crystal_%d" % k)
		k += 1


func _node_standin(holder: Node3D, n: Dictionary) -> void:
	var tint := Color.html(n.tint)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.21, 0.28, 0.16)
	m.roughness = 0.9
	if n.kind == "herb":
		var st := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.add_uv2 = true   # static for the bake: lightmap UVs
		cm.top_radius = 0.03
		cm.bottom_radius = 0.06
		cm.height = 0.4
		cm.radial_segments = 5
		st.mesh = cm
		st.material_override = m
		st.position = Vector3(0, 0.2, 0)
		_add(holder, st, "stem")
		var cap := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.add_uv2 = true   # static for the bake: lightmap UVs
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
		_add(holder, cap, "cap")
	elif n.kind == "pool":
		var qm := QuadMesh.new()
		qm.size = Vector2(1.6, 1.6)
		qm.orientation = PlaneMesh.FACE_Y
		var rm := StandardMaterial3D.new()
		rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		rm.albedo_texture = _ring_tex
		rm.texture_filter = SHARP
		rm.albedo_color = Color(tint.r * 2.0, tint.g * 2.0, tint.b * 2.0, 0.28)
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = rm
		mi.position = Vector3(0, 0.09, 0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_add(holder, mi, "ring")
	elif n.kind == "tree":
		var tm := MeshInstance3D.new()
		var cm2 := CylinderMesh.new()
		cm2.add_uv2 = true   # static for the bake: lightmap UVs
		cm2.top_radius = 0.2
		cm2.bottom_radius = 0.35
		cm2.height = 2.4
		cm2.radial_segments = 7
		tm.mesh = cm2
		var tmat := StandardMaterial3D.new()
		tmat.albedo_color = Color(0.24, 0.18, 0.14)
		tm.material_override = tmat
		tm.position = Vector3(0, 1.2, 0)
		_add(holder, tm, "trunk")


# ---------------------------------------------------------------- decals, water, dressing
func _flat(parent: Node3D, name: String, size: Vector2, mat: Material, pos: Vector3, yaw: float) -> MeshInstance3D:
	var qm := QuadMesh.new()
	qm.size = size
	qm.orientation = PlaneMesh.FACE_Y
	var mi := MeshInstance3D.new()
	mi.mesh = qm
	mi.material_override = mat
	mi.position = pos
	mi.rotation.y = yaw
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED   # unshaded and see-through: nothing to light or bake
	return _add(parent, mi, name) as MeshInstance3D


func _decals(parent: Node3D) -> void:
	var n := 0
	for d: Dictionary in world.decals:
		if d.area != area_id:
			continue
		var col := Color.html(d.color)
		var sigil: bool = d.kind == "sigil"
		var mat: StandardMaterial3D = _shared("decal:%s:%s:%s" % [d.kind, d.color, d.opacity], func() -> StandardMaterial3D:
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.texture_filter = SHARP
			if sigil:
				m.albedo_texture = _ring_tex
				m.albedo_color = Color(col, float(d.opacity))
			else:
				# Blood and cracks: a dark soft stain (the web paints irregular canvas shapes).
				m.albedo_texture = _glow_tex
				m.albedo_color = Color(col.r * 0.6, col.g * 0.6, col.b * 0.6, float(d.opacity) * 0.8)
			return m)
		_flat(parent, "%s_%02d" % [d.kind, n], Vector2(d.r * 2.0, d.r * 2.0), mat, Vector3(d.x, 0.03 if sigil else 0.02, d.z), d.rot)
		n += 1
	# The puddles are the world dressing's (DmWfxWater draws them with the water, one mesh): no quad of their own.


## world_builder._water: `water` is the Nave's channels, `bog` the Fen's, `ponds` the Acre's (deep: they block feet). Each lies in its area's rect. The water is drawn by the world dressing
## (DmWfxWater: one mesh with the fresnel, the moon's glint and the ripples), so a pond is only its collider here.
func _water() -> void:
	var n := 0
	for r: Dictionary in world.ponds:
		if _area_of_rect(r) == area_id:
			_body(Vector3((r.x0 + r.x1) / 2.0, 1.5, (r.z0 + r.z1) / 2.0), _box_shape(Vector3(r.x1 - r.x0, 3.0, r.z1 - r.z0)), "pond_%02d" % n)
			n += 1


func _wing_floor(parent: Node3D) -> void:
	var n := 0
	for f: Dictionary in world.wingFloor:
		var col := Color.html(f.color)
		var rug: bool = f.kind == "rug"
		var m := StandardMaterial3D.new()
		m.roughness = 1.0
		if rug:
			m.albedo_color = col * 0.45
		else:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_texture = _glow_tex
			m.albedo_color = Color(col, 0.8)
		var mi := _flat(parent, "%s_%02d" % [f.kind, n], Vector2(f.w, f.d), m, Vector3(f.x, 0.012 if rug else 0.014, f.z), f.rot)
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC if rug else GeometryInstance3D.GI_MODE_DISABLED
		if rug:
			(mi.mesh as QuadMesh).add_uv2 = true   # baked with the floor: lightmap UVs
		if rug and f.alt != null:
			var tmat := StandardMaterial3D.new()
			tmat.roughness = 1.0
			tmat.albedo_color = col * 0.8
			var ti := _flat(parent, "%s_%02d_trim" % [f.kind, n], Vector2(f.w - 0.5, f.d - 0.5), tmat, Vector3(f.x, 0.016, f.z), f.rot)
			ti.gi_mode = GeometryInstance3D.GI_MODE_STATIC
			(ti.mesh as QuadMesh).add_uv2 = true
		n += 1


## The web's WorldView.buildHummocks: a low peat mound (muted green) with a pale teal rim ring, two draw calls for all of them.
func _hummocks(parent: Node3D) -> void:
	var items: Array = []
	for h: Dictionary in world.hummocks:
		if _area_of_point(h.x, h.z) == area_id:
			items.append(h)
	if items.is_empty():
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.html("#46574a") * 0.45
	mat.roughness = 1.0
	mat.emission_enabled = true
	mat.emission = Color.html("#0a2622")
	mat.emission_energy_multiplier = 0.3
	var cm := CylinderMesh.new()
	cm.top_radius = 0.9
	cm.bottom_radius = 1.0
	cm.height = 0.34
	cm.radial_segments = 18
	var rim_mat := StandardMaterial3D.new()
	rim_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rim_mat.albedo_color = Color(0.435, 0.839, 0.769, 0.38)
	rim_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rim_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	rim_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = cm
	mm.instance_count = items.size()
	var mr := MultiMesh.new()
	mr.transform_format = MultiMesh.TRANSFORM_3D
	mr.mesh = _hummock_ring_mesh()
	mr.instance_count = items.size()
	var mound_buf := PackedFloat32Array()
	var rim_buf := PackedFloat32Array()
	for h: Dictionary in items:
		mound_buf.append_array(_mm_row(Transform3D(Basis.from_scale(Vector3(h.r, 1.0, h.r)), Vector3(h.x, 0.17, h.z))))
		rim_buf.append_array(_mm_row(Transform3D(Basis.from_scale(Vector3(h.r, 1.0, h.r)), Vector3(h.x, 0.0, h.z))))
	mm.buffer = mound_buf
	mr.buffer = rim_buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	_add(parent, mmi, "hummocks")
	var rmi := MultiMeshInstance3D.new()
	rmi.multimesh = mr
	rmi.material_override = rim_mat
	rmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_add(parent, rmi, "hummock_rims")


## A flat ring (radius 0.93 to 1.07) 0.36 above the ground, the web's hummock rim.
func _hummock_ring_mesh() -> ArrayMesh:
	var segs := 36
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in segs:
		var ang := TAU * i / segs
		verts.append(Vector3(cos(ang) * 0.93, 0.36, sin(ang) * 0.93))
		verts.append(Vector3(cos(ang) * 1.07, 0.36, sin(ang) * 1.07))
	for i in segs:
		var j := (i + 1) % segs
		idx.append_array(PackedInt32Array([i * 2, i * 2 + 1, j * 2, i * 2 + 1, j * 2 + 1, j * 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


# ---------------------------------------------------------------- doors and gates
## Every door that touches this area: its corridor floor and, unless it is always open, its gate (posts, lintel, bars, seal, a solid body).
## A door between two areas is in both scenes with the same id and place (the area loader keeps one copy). A gate starts as world_builder leaves it
## after building: closed, except the doors world.json lists as open, which world_builder._apply_unlock_state opens at once.
func _doors(parent: Node3D) -> void:
	for d: Dictionary in world.doors:
		if d.a != area_id and d.b != area_id:
			continue
		var holder := _group(parent, String(d.id))
		holder.set_meta("door_id", d.id)
		holder.set_meta("areas", [d.a, d.b])
		var always_open: bool = d.id == "chapter_graves"
		holder.set_meta("always_open", always_open)
		_ground(holder, "floor", d.rect.x0, d.rect.z0, d.rect.x1, d.rect.z1, "chapter", 0.005)
		if not always_open:
			_gate(holder, d, d.open)


## A MultiMesh transform as the 12 floats of its buffer (basis rows, origin last). The headless renderer keeps nothing set with set_instance_transform.
func _mm_row(t: Transform3D) -> PackedFloat32Array:
	return PackedFloat32Array([t.basis.x.x, t.basis.y.x, t.basis.z.x, t.origin.x, t.basis.x.y, t.basis.y.y, t.basis.z.y, t.origin.y, t.basis.x.z, t.basis.y.z, t.basis.z.z, t.origin.z])


func _gate(parent: Node3D, d: Dictionary, open: bool) -> void:
	var bar_mat: StandardMaterial3D = _shared("gate_bar", func() -> StandardMaterial3D:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color.html("#24212a")
		m.roughness = 0.6
		m.metallic = 0.6
		return m)
	var post_mat: StandardMaterial3D = _shared("gate_post", func() -> StandardMaterial3D:
		var m := StandardMaterial3D.new()
		m.albedo_texture = _tex("stone_wall")
		m.texture_filter = SHARP
		m.albedo_color = DmCompatAlbedo.tint("stone_wall", Color.html("#8a8296"))
		m.roughness = 0.9
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3.ONE / 4.0
		return m)
	var seal_mat: StandardMaterial3D = _shared("gate_seal", func() -> StandardMaterial3D:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.albedo_texture = _ring_tex
		m.texture_filter = SHARP
		m.albedo_color = Color(0.61, 0.36, 1.0, 0.9)
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		return m)
	var width: float = d.width
	var gate := Node3D.new()
	gate.position = Vector3(d.cx, 0, d.cz)
	gate.rotation.y = 0.0 if d.axis == "z" else PI / 2.0
	_add(parent, gate, "gate")
	var k := 0
	for s in [-1.0, 1.0]:
		var pb := BoxMesh.new()
		pb.size = Vector3(1, 5, 1)
		pb.add_uv2 = true
		var post := MeshInstance3D.new()
		post.mesh = pb
		post.material_override = post_mat
		post.position = Vector3(s * (width + 1.0) / 2.0, 2.5, 0)
		_add(gate, post, "post_%d" % k)
		k += 1
	var lb := BoxMesh.new()
	lb.size = Vector3(width + 2.0, 0.9, 1.0)
	lb.add_uv2 = true
	var lintel := MeshInstance3D.new()
	lintel.mesh = lb
	lintel.material_override = post_mat
	lintel.position = Vector3(0, 5.2, 0)
	_add(gate, lintel, "lintel")
	# The bars rise out of the way when the door opens: the runtime moves this node (world_builder.set_door_open).
	var bars := _group(gate, "bars")
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
	var buf := PackedFloat32Array()
	for i in n + 1:
		buf.append_array(_mm_row(Transform3D(Basis.IDENTITY, Vector3(-width / 2.0 + i * width / n, 2.4, 0))))
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = bar_mat
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_add(bars, mmi, "bars")
	var r := 0
	for y in [0.9, 3.2]:
		var rb := BoxMesh.new()
		rb.size = Vector3(width, 0.08, 0.1)
		var rail := MeshInstance3D.new()
		rail.mesh = rb
		rail.material_override = bar_mat
		rail.position = Vector3(0, y, 0)
		rail.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_add(bars, rail, "rail_%d" % r)
		r += 1
	var seal := MeshInstance3D.new()
	var sq := QuadMesh.new()
	sq.size = Vector2(width * 0.9, width * 0.9)
	seal.mesh = sq
	seal.material_override = seal_mat
	seal.position = Vector3(0, 2.5, 0.12)
	seal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	seal.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_add(bars, seal, "seal")
	# The gate body: a solid collider across the corridor (the web's nav simply has no walkable corridor while sealed).
	var body := StaticBody3D.new()
	_add(gate, body, "body")
	var cs := CollisionShape3D.new()
	cs.shape = _box_shape(Vector3(width, 5.0, 1.0))
	cs.position = Vector3(0, 2.5, 0)
	_add(body, cs, "collider")
	if open:   # world_builder.set_door_open(id, true, instant): the bars up and hidden, the body off
		bars.position.y = 5.0
		bars.visible = false
		cs.disabled = true


# ---------------------------------------------------------------- navigation (baked here, not at start-up)
func _outline_circle(x: float, z: float, r: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in 10:
		var ang := TAU * i / 10.0
		pts.append(Vector3(x + cos(ang) * r, 0, z + sin(ang) * r))
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


## The settings of world_builder._nav_mesh.
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


## Every obstruction of the whole world (world_builder._all_obstacles); a region bakes the ones near it.
func _all_obstacles() -> Array:
	var out: Array = []
	for w: Dictionary in world.walls:
		var b := _nbox(w.box)
		out.append({"x0": b.x0, "z0": b.z0, "x1": b.x1, "z1": b.z1, "poly": _outline_box(b.x0, b.z0, b.x1, b.z1)})
	for w: Dictionary in world.depths.walls:
		var b2 := _nbox(w.box)
		out.append({"x0": b2.x0, "z0": b2.z0, "x1": b2.x1, "z1": b2.z1, "poly": _outline_box(b2.x0, b2.z0, b2.x1, b2.z1)})
	var plist: Array = world.props.duplicate()
	plist.append_array(world.depths.props)
	for p: Dictionary in plist:
		var o: Variant = p.obstacle
		if o == null:
			continue
		if o.kind == "circle":
			out.append({"x0": o.x - o.r - GROW, "z0": o.z - o.r - GROW, "x1": o.x + o.r + GROW, "z1": o.z + o.r + GROW, "poly": _outline_circle(o.x, o.z, o.r + GROW)})
		else:
			out.append({"x0": o.x0 - GROW, "z0": o.z0 - GROW, "x1": o.x1 + GROW, "z1": o.z1 + GROW, "poly": _outline_box(o.x0 - GROW, o.z0 - GROW, o.x1 + GROW, o.z1 + GROW)})
	for n: Dictionary in world.nodes:
		if float(n.collider) > 0.0:
			var r: float = float(n.collider) + GROW
			out.append({"x0": n.x - r, "z0": n.z - r, "x1": n.x + r, "z1": n.z + r, "poly": _outline_circle(n.x, n.z, r)})
	for pd: Dictionary in world.ponds:
		out.append({"x0": pd.x0 - GROW, "z0": pd.z0 - GROW, "x1": pd.x1 + GROW, "z1": pd.z1 + GROW, "poly": _outline_box(pd.x0 - GROW, pd.z0 - GROW, pd.x1 + GROW, pd.z1 + GROW)})
	return out


func _bake_region(name: String, faces: PackedVector3Array, r: Dictionary, obstacles: Array, enabled: bool) -> NavigationRegion3D:
	var src := NavigationMeshSourceGeometryData3D.new()
	src.add_faces(faces, Transform3D.IDENTITY)
	for o: Dictionary in obstacles:
		if _near(r, o.x0, o.z0, o.x1, o.z1, NAV_PAD):
			src.add_projected_obstruction(o.poly, -0.5, 3.0, true)
	var nm := _nav_mesh()
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	var reg := NavigationRegion3D.new()
	reg.navigation_mesh = nm
	reg.enabled = enabled
	_add(_nav, reg, name)
	return reg


## The area's region and, for every door touching it, the corridor region and the two links joining it to its rooms across the one-metre
## overlap (both ends sit inside both regions' eroded edges). A door's region and links start enabled when world.json lists the door as open,
## disabled otherwise; the runtime enables them when a sealed door opens (world_builder.set_door_open).
func _bake_nav() -> void:
	var obstacles := _all_obstacles()
	_bake_region("area_" + area_id, _quad_faces(rect), rect, obstacles, true)
	for d: Dictionary in world.doors:
		if d.a != area_id and d.b != area_id:
			continue
		var open: bool = d.open
		var reg := _bake_region("door_" + String(d.id), _quad_faces(d.rect), d.rect, obstacles, open)
		reg.set_meta("door_id", d.id)
		var k := 0
		for room_id: String in [d.a, d.b]:
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
			link.enabled = open
			link.set_meta("door_id", d.id)
			_add(_nav, link, "link_%s_%d" % [d.id, k])
			k += 1
