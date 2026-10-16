class_name DmStairMesh
extends RefCounted
## The Depths' stairs from primitives (the web's StairView, no new art): a stone frame round a dark well with five steps funnelling down into it
## (the way down) or climbing out of it (the way up). The stone and steps are ONE cached vertex-coloured ArrayMesh per direction (one draw call
## each, shared by every stair on every floor); the well is a flat quad that takes the caller's emissive material, so the caller keeps driving
## the glow (sealed / open). The footprint stays inside the 2 m square around the stair point; the navmesh circle for it is DmDepthsFloor.STAIR_R.

const WELL := 1.5     ## well side, metres
const FRAME := 0.25   ## frame thickness
const STEPS := 5
const STONE := Color(0.27, 0.25, 0.225)
const STEP_DOWN := Color(0.31, 0.285, 0.26)
const STEP_UP := Color(0.35, 0.335, 0.305)

static var _meshes: Dictionary = {}   ## up(bool) -> ArrayMesh
static var _stone_mat: StandardMaterial3D = null
static var _well_mesh: QuadMesh = null


## A stair at the origin of a new Node3D: {Stone, Well}. `well_mat` is the glowing material of the well (caller-owned, may be shared).
static func make(up: bool, well_mat: Material) -> Node3D:
	var root := Node3D.new()
	root.name = "Stair"
	var stone := MeshInstance3D.new()
	stone.name = "Stone"
	stone.mesh = _mesh(up)
	stone.material_override = _material()
	stone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(stone)
	if _well_mesh == null:
		_well_mesh = QuadMesh.new()
		_well_mesh.size = Vector2(WELL, WELL)
		_well_mesh.orientation = PlaneMesh.FACE_Y
	var well := MeshInstance3D.new()
	well.name = "Well"
	well.mesh = _well_mesh
	well.material_override = well_mat
	well.position.y = 0.02
	well.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(well)
	return root


static func _material() -> StandardMaterial3D:
	if _stone_mat == null:
		_stone_mat = StandardMaterial3D.new()
		_stone_mat.vertex_color_use_as_albedo = true
		_stone_mat.vertex_color_is_srgb = true
		_stone_mat.roughness = 0.95
	return _stone_mat


static func _mesh(up: bool) -> ArrayMesh:
	if _meshes.has(up):
		return _meshes[up]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var half := WELL / 2.0
	var o := half + FRAME / 2.0
	_box(verts, norms, cols, idx, Vector3(WELL + FRAME * 2.0, 0.3, FRAME), Vector3(0, 0.15, -o), STONE)
	_box(verts, norms, cols, idx, Vector3(WELL + FRAME * 2.0, 0.3, FRAME), Vector3(0, 0.15, o), STONE)
	_box(verts, norms, cols, idx, Vector3(FRAME, 0.3, WELL), Vector3(-o, 0.15, 0), STONE)
	_box(verts, norms, cols, idx, Vector3(FRAME, 0.3, WELL), Vector3(o, 0.15, 0), STONE)
	var depth := (WELL - 0.2) / STEPS
	for i in STEPS:
		var t := float(i) / float(STEPS - 1)
		var h := (0.1 + 0.08 * i) if up else 0.08
		var base := STEP_UP if up else STEP_DOWN
		var shade := (0.7 + 0.3 * t) if up else (1.0 - 0.62 * t)
		var c := Color(base.r * shade, base.g * shade, base.b * shade)
		var width := WELL - 0.1 - i * 0.2
		_box(verts, norms, cols, idx, Vector3(width, h, depth), Vector3(0, h / 2.0 + 0.02, half - 0.1 - depth * (i + 0.5)), c)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_meshes[up] = m
	return m


static func _box(verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array, size: Vector3, at: Vector3, c: Color) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	var a := bm.get_mesh_arrays()
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var ix: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var first := verts.size()
	for i in v.size():
		verts.append(v[i] + at)
		norms.append(n[i])
		cols.append(c)
	for i in ix:
		idx.append(first + i)
