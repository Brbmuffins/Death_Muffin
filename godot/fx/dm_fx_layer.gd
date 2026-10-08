class_name DmFxLayer
extends RefCounted
## Port of the instanced layers in Effects.ts (DecalLayer) and fxLayers.ts (SpriteLayer, BeamLayer): every live ground decal /
## billboard of one texture + blend mode (or every live tether) drawn as ONE MultiMesh, with per-instance tint (instance colour),
## opacity (and outline amount for decals) in INSTANCE_CUSTOM. Items are written each frame by their transient, then flush()ed.

enum Kind { DECAL, SPRITE, BEAM }

class Item:
	var x := 0.0
	var y := 0.0
	var z := 0.0
	var rot_y := 0.0   # decal yaw / sprite view-axis rotation
	var sx := 0.0      # decal x scale / sprite size / beam width
	var sz := 0.0      # decal z scale / beam length
	var tx := 0.0      # beam far end
	var ty := 0.0
	var tz := 1.0
	var color := Color.WHITE  # linear
	var opacity := 0.0
	var rim := 0.0

var kind: Kind
var items: Array = []
var idle_s := 0.0
var node: MultiMeshInstance3D
var mm: MultiMesh
var capacity: int
var _parent: Node3D
var _buf := PackedFloat32Array()
var _mat: ShaderMaterial
var _mesh: Mesh
var _shown := false   # last state pushed to the MultiMesh / node (an empty layer is not re-pushed every frame)
static var _meshes: Dictionary = {}


## shape: "quad" | "disc" | "ring" (footprint meshes: same lit pixels, less fill, see fxLayers.ts footprintGeometry).
func _init(parent: Node3D, k: Kind, tex: Texture2D, additive: bool, shape: String, order: int, outline: Variant, cap: int = 32) -> void:
	_parent = parent
	kind = k
	capacity = cap
	var kname := "decal" if k == Kind.DECAL else ("sprite" if k == Kind.SPRITE else "beam")
	_mat = DmFxTex.material(kname, additive, tex, order)
	if k == Kind.DECAL:
		var edge := 2.0
		var fl := 1.0
		if outline is Dictionary:
			edge = float(outline["edge"])
			fl = float(outline["floor"])
		_mat.set_shader_parameter("rim_edge", edge)
		_mat.set_shader_parameter("rim_floor", fl)
	_mesh = _mesh_for(k, shape)
	_make()


static func _mesh_for(k: Kind, shape: String) -> Mesh:
	var key := "%d|%s" % [k, shape]
	if _meshes.has(key):
		return _meshes[key]
	var m: Mesh
	if k == Kind.BEAM:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 1.0
		cyl.bottom_radius = 1.0
		cyl.height = 1.0
		cyl.radial_segments = 6
		cyl.rings = 1
		cyl.cap_top = false
		cyl.cap_bottom = false
		# Along +Z (three: CylinderGeometry rotateX(PI/2)); lookAt then aims +Z at the far end.
		var st := SurfaceTool.new()
		st.create_from(cyl, 0)
		var arr := st.commit_to_arrays()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var rot := Basis(Vector3.RIGHT, PI / 2.0)
		for i in verts.size():
			verts[i] = rot * verts[i]
		arr[Mesh.ARRAY_VERTEX] = verts
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		m = am
	elif shape == "quad":
		if k == Kind.DECAL:
			var pm := PlaneMesh.new()
			pm.size = Vector2(1, 1)
			m = pm
		else:
			var qm := QuadMesh.new()
			qm.size = Vector2(1, 1)
			m = qm
	else:
		m = _footprint(shape, k == Kind.DECAL)
	_meshes[key] = m
	return m


## fxLayers.ts footprintGeometry: 16-gon around the inscribed circle ('disc') or its annulus ('ring'). flat = XZ, else XY.
static func _footprint(kind_name: String, flat: bool, sides: int = 16) -> ArrayMesh:
	var outer := 0.5 / cos(PI / float(sides))
	var inner := 0.348 if kind_name == "ring" else 0.0
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var nrm := PackedVector3Array()
	var idx := PackedInt32Array()
	var put := func(x: float, y: float) -> void:
		if flat:
			pos.append(Vector3(x, 0, y))
			uv.append(Vector2(x + 0.5, 0.5 + y))
			nrm.append(Vector3.UP)
		else:
			pos.append(Vector3(x, y, 0))
			uv.append(Vector2(x + 0.5, 0.5 - y))
			nrm.append(Vector3.BACK)
	if inner == 0.0:
		put.call(0.0, 0.0)
	for i in sides:
		var a := (float(i) + 0.5) / float(sides) * TAU
		put.call(cos(a) * outer, sin(a) * outer)
	if inner == 0.0:
		for i in sides:
			idx.append_array([0, 1 + i, 1 + ((i + 1) % sides)])
	else:
		for i in sides:
			var a2 := (float(i) + 0.5) / float(sides) * TAU
			put.call(cos(a2) * inner, sin(a2) * inner)
		for i in sides:
			var j := (i + 1) % sides
			idx.append_array([i, sides + i, j, j, sides + i, sides + j])
	# Winding: make both faces visible regardless (materials are cull_disabled).
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


func _make() -> void:
	if node != null:
		node.queue_free()
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _mesh
	mm.instance_count = capacity
	mm.visible_instance_count = 0
	_buf = PackedFloat32Array()
	_buf.resize(capacity * 20)
	node = MultiMeshInstance3D.new()
	node.multimesh = mm
	node.material_override = _mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = AABB(Vector3(-500, -500, -500), Vector3(1000, 1000, 1000))
	node.visible = false
	_shown = false
	_parent.add_child(node)


func add(it: Item) -> void:
	items.append(it)
	if items.size() > capacity:
		capacity *= 2
		_make()


func remove(it: Item) -> void:
	items.erase(it)


func flush() -> void:
	if items.is_empty():
		_hide()
		return
	var n := 0
	for it in items:
		var item: Item = it
		var floor_op := 0.0 if kind == Kind.DECAL else 0.001
		if item.opacity <= floor_op:
			continue
		var o := n * 20
		match kind:
			Kind.DECAL:
				var s := sin(item.rot_y)
				var c := cos(item.rot_y)
				_buf[o] = c * item.sx
				_buf[o + 1] = 0.0
				_buf[o + 2] = s * item.sz
				_buf[o + 3] = item.x
				_buf[o + 4] = 0.0
				_buf[o + 5] = 1.0
				_buf[o + 6] = 0.0
				_buf[o + 7] = item.y
				_buf[o + 8] = -s * item.sx
				_buf[o + 9] = 0.0
				_buf[o + 10] = c * item.sz
				_buf[o + 11] = item.z
				_buf[o + 16] = item.opacity
				_buf[o + 17] = item.rim
			Kind.SPRITE:
				_buf[o] = item.sx
				_buf[o + 1] = 0.0
				_buf[o + 2] = 0.0
				_buf[o + 3] = item.x
				_buf[o + 4] = 0.0
				_buf[o + 5] = item.sx
				_buf[o + 6] = 0.0
				_buf[o + 7] = item.y
				_buf[o + 8] = 0.0
				_buf[o + 9] = 0.0
				_buf[o + 10] = item.sx
				_buf[o + 11] = item.z
				_buf[o + 16] = item.rot_y
				_buf[o + 17] = item.opacity
			Kind.BEAM:
				var from := Vector3(item.x, item.y, item.z)
				var to := Vector3(item.tx, item.ty, item.tz)
				var dir := to - from
				var b := Basis.IDENTITY
				if dir.length_squared() > 1e-10:
					var z_axis := dir.normalized()
					var up := Vector3.UP if absf(z_axis.dot(Vector3.UP)) < 0.999 else Vector3.RIGHT
					var x_axis := up.cross(z_axis).normalized()
					var y_axis := z_axis.cross(x_axis)
					b = Basis(x_axis * item.sx, y_axis * item.sx, z_axis * item.sz)
				_buf[o] = b.x.x
				_buf[o + 1] = b.y.x
				_buf[o + 2] = b.z.x
				_buf[o + 3] = item.x
				_buf[o + 4] = b.x.y
				_buf[o + 5] = b.y.y
				_buf[o + 6] = b.z.y
				_buf[o + 7] = item.y
				_buf[o + 8] = b.x.z
				_buf[o + 9] = b.y.z
				_buf[o + 10] = b.z.z
				_buf[o + 11] = item.z
				_buf[o + 16] = item.opacity
		_buf[o + 12] = item.color.r
		_buf[o + 13] = item.color.g
		_buf[o + 14] = item.color.b
		_buf[o + 15] = 1.0
		_buf[o + 18] = 0.0
		_buf[o + 19] = 0.0
		n += 1
	if n == 0:
		_hide()
		return
	_shown = true
	mm.visible_instance_count = n
	node.visible = true
	mm.buffer = _buf


## Nothing to draw: tell the MultiMesh once, not on every idle frame (each layer used to repeat two server calls per frame while empty).
func _hide() -> void:
	if _shown:
		_shown = false
		mm.visible_instance_count = 0
		node.visible = false


func dispose() -> void:
	if node != null:
		node.queue_free()
		node = null
