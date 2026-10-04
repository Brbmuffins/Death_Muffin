class_name DmNodeViews
extends Node3D
## Port of `NodeViews` in src/graphics/NodeViews.ts: every gathering node's live / spent look, the hover ring, the selected ring and the
## gatherer's progress arc. The node props themselves are the ones DmWorldBuilder._nodes() already builds (`builder.node_views`:
## id -> Node3D); this class only swaps them to a spent look and draws the rings. Add it under the world root at the origin.
##
##   views.setup(builder)            # once, after builder.build()
##   views.hover(node, ok) / selected(node) / progress(px, pz, frac, color) / set_live(id, on) / update(dt)

const BONE := Color(0.7843137, 0.7450980, 0.6588235)    # INDICATOR_BONE 0xc8bea8
const ARC_SEGMENTS := 48

var _props: Dictionary = {}      # id -> Node3D
var _defs: Dictionary = {}       # id -> world node Dictionary
var _live_kids: Dictionary = {}  # id -> Array of the live look's children
var _spent: Dictionary = {}      # id -> Node3D (lazily built spent look)
var _pools: Array = []           # {mats: Array[StandardMaterial3D], phase}
var _time := 0.0
var _hover: MeshInstance3D
var _selected: MeshInstance3D
var _arc: MeshInstance3D
var _hover_mat: StandardMaterial3D
var _selected_mat: StandardMaterial3D
var _arc_mat: StandardMaterial3D
var _arc_meshes: Dictionary = {}


func _init() -> void:
	name = "NodeViews"
	_hover_mat = _ring_mat(Color(0.9098, 0.8627, 0.7529, 0.6))
	_selected_mat = _ring_mat(Color(0.9098, 0.8627, 0.7529, 0.45))
	_arc_mat = _ring_mat(Color(0.9098, 0.8627, 0.7529, 0.74))
	_hover = _ring_instance(_ring_mesh(1.05, 1.22, 40, 40), _hover_mat)
	_selected = _ring_instance(_ring_mesh(0.9, 1.02, 40, 40), _selected_mat)
	_arc = _ring_instance(null, _arc_mat)
	add_child(_hover)
	add_child(_selected)
	add_child(_arc)


static func _ring_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.render_priority = 3
	m.albedo_color = c
	return m


func _ring_instance(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Flat ring on the XZ plane, `drawn` of `segments` segments (TS RingGeometry + setDrawRange).
static func _ring_mesh(r_in: float, r_out: float, segments: int, drawn: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in segments + 1:
		var a := float(i) / float(segments) * TAU
		verts.append(Vector3(cos(a) * r_in, 0, sin(a) * r_in))
		verts.append(Vector3(cos(a) * r_out, 0, sin(a) * r_out))
	for i in drawn:
		var b := i * 2
		idx.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func setup(builder) -> void:    # DmWorldBuilder (duck-typed: node_views, world.nodes, area_nodes)
	_props = builder.node_views
	var pool_groups: Dictionary = {}
	var glow_mesh: Mesh = null
	for n in builder.world.nodes:
		var id: String = n["id"]
		if not _props.has(id):
			continue
		_defs[id] = n
		var prop: Node3D = _props[id]
		_live_kids[id] = prop.get_children()
		if n.get("rich", false):
			prop.scale = Vector3.ONE * 1.12
			# Rich nodes: a faint glow disc so fighters notice them.
			if glow_mesh == null:
				glow_mesh = _glow_mesh()
			var glow := MeshInstance3D.new()
			glow.mesh = glow_mesh
			glow.position = Vector3(n["x"], 0.03, n["z"])
			glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			(builder.area_nodes[n["area"]] as Node3D).add_child(glow)
		if n["kind"] == "pool":
			var key := "%s:%s" % [n["area"], n["type"]]
			if not pool_groups.has(key):
				pool_groups[key] = {"mats": [], "phase": float(String(n["type"]).length())}
			for k in _live_kids[id]:
				if k is MeshInstance3D and (k as MeshInstance3D).material_override is StandardMaterial3D:
					pool_groups[key]["mats"].append((k as MeshInstance3D).material_override)
	_pools = pool_groups.values()


static func _glow_mesh() -> Mesh:
	var m := ArrayMesh.new()
	var verts := PackedVector3Array([Vector3.ZERO])
	var idx := PackedInt32Array()
	for i in 25:
		var a := float(i) / 24.0 * TAU
		verts.append(Vector3(cos(a) * 1.4, 0, sin(a) * 1.4))
	for i in 24:
		idx.append_array([0, i + 2, i + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.albedo_color = Color(0.851, 0.761, 0.478, 0.16)
	m.surface_set_material(0, mat)
	return m


## Show a node live (true) or spent (false).
func set_live(id: String, live: bool) -> void:
	if not _props.has(id):
		return
	for k in _live_kids[id]:
		if is_instance_valid(k):
			(k as Node3D).visible = live
	if not live and not _spent.has(id):
		_spent[id] = _build_spent(id)
	if _spent.has(id):
		(_spent[id] as Node3D).visible = not live


## The spent look: the pipeline spent model when the node has one, else the code-built stand-in (bare stalks for herbs, nothing for pools).
func _build_spent(id: String) -> Node3D:
	var n: Dictionary = _defs[id]
	var root := Node3D.new()
	root.visible = false
	(_props[id] as Node3D).add_child(root)
	var sm: Variant = n.get("spentModel", null)
	if sm != null:
		for part in DmModels.prop_parts(str(sm), float(n["spentHeight"])):
			var mi := MeshInstance3D.new()
			mi.mesh = part.mesh
			mi.transform = part.local
			root.add_child(mi)
	elif n["kind"] == "herb":
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.html("#2e3a22")
		for s in [[0.0, 0.0, 0.12], [0.18, 0.08, 0.1], [-0.16, -0.1, 0.09]]:
			var cm := CylinderMesh.new()
			cm.top_radius = 0.025
			cm.bottom_radius = 0.05
			cm.height = float(s[2])
			cm.radial_segments = 5
			var mi := MeshInstance3D.new()
			mi.mesh = cm
			mi.material_override = mat
			mi.position = Vector3(s[0], float(s[2]) / 2.0, s[1])
			root.add_child(mi)
	return root


static func _skill_color(node: Dictionary) -> Color:
	var def := DmGathering.node_def(node["type"])
	return Color.html(DmGatherData.get_data()["skills"][def["skill"]]["color"])


static func _ring_scale(kind: String, tree: float, pool: float, other: float) -> float:
	return tree if kind == "tree" else (pool if kind == "pool" else other)


func hover(node: Variant, usable: bool = true) -> void:
	_hover.visible = node != null and not (node is Dictionary and node.is_empty())
	if not _hover.visible:
		return
	var def := DmGathering.node_def(node["type"])
	_hover.position = Vector3(node["x"], 0.04, node["z"])
	_hover.scale = Vector3.ONE * _ring_scale(def["kind"], 1.0, 1.25, 0.95)
	var c := _skill_color(node) if usable else Color.html("#c0504d")
	if usable:
		c = c.lerp(BONE, 0.25)
	c.a = _hover_mat.albedo_color.a
	_hover_mat.albedo_color = c


## The current gathering target, including walking and respawn waits.
func selected(node: Variant) -> void:
	_selected.visible = node != null and not (node is Dictionary and node.is_empty())
	if not _selected.visible:
		return
	var def := DmGathering.node_def(node["type"])
	_selected.position = Vector3(node["x"], 0.035, node["z"])
	_selected.scale = Vector3.ONE * _ring_scale(def["kind"], 1.0, 1.25, 0.95)
	var c := _skill_color(node).lerp(BONE, 0.4)
	c.a = _selected_mat.albedo_color.a
	_selected_mat.albedo_color = c


## The progress arc under the hero while a work cycle runs (frac 0 hides it).
func progress(px: float, pz: float, frac: float, skill_color: String) -> void:
	_arc.visible = frac > 0.0
	if not _arc.visible:
		return
	_arc.position = Vector3(px, 0.05, pz)
	var segs := int(ceil(clampf(frac, 0.0, 1.0) * ARC_SEGMENTS))
	if not _arc_meshes.has(segs):
		_arc_meshes[segs] = _ring_mesh(0.62, 0.8, ARC_SEGMENTS, segs)
	_arc.mesh = _arc_meshes[segs]
	var c := Color.html(skill_color).lerp(BONE, 0.3)
	c.a = _arc_mat.albedo_color.a
	_arc_mat.albedo_color = c


func update(dt: float) -> void:
	_time += dt
	var c := _selected_mat.albedo_color
	c.a = 0.42 + sin(_time * 1.8) * 0.06
	_selected_mat.albedo_color = c
	# Fishing spots breathe: a slow pulse so the eye finds them on dark water.
	for p in _pools:
		var opacity := 0.28 + sin(_time * 1.2 + float(p["phase"])) * 0.05
		for m: StandardMaterial3D in p["mats"]:
			var mc := m.albedo_color
			mc.a = opacity
			m.albedo_color = mc
