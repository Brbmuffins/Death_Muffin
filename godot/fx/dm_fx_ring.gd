class_name DmFxRing
extends RefCounted
## Port of Effects.ts ParticleSystem: a CPU-simulated ring buffer of motes drawn as one MultiMesh of billboards per blend mode
## (additive "glow" ring of 3500, normal-blend "smoke" ring of 900). Same emit options, same alpha/size curves.

var node: MultiMeshInstance3D
var mm: MultiMesh
var capacity: int

var _pos: PackedFloat32Array
var _vel: PackedFloat32Array
var _col: PackedFloat32Array
var _life: PackedFloat32Array
var _max_life: PackedFloat32Array
var _base_size: PackedFloat32Array
var _grav: PackedFloat32Array
var _drag: PackedFloat32Array
var _shrink: PackedFloat32Array
var _buf: PackedFloat32Array
var _cursor := 0
var _active := 0
var _list: PackedInt32Array = PackedInt32Array()  # indices of live motes


func _init(cap: int, tex: Texture2D, additive: bool) -> void:
	capacity = cap
	_pos = PackedFloat32Array(); _pos.resize(cap * 3)
	_vel = PackedFloat32Array(); _vel.resize(cap * 3)
	_col = PackedFloat32Array(); _col.resize(cap * 3)
	_life = PackedFloat32Array(); _life.resize(cap)
	_max_life = PackedFloat32Array(); _max_life.resize(cap)
	_base_size = PackedFloat32Array(); _base_size.resize(cap)
	_grav = PackedFloat32Array(); _grav.resize(cap)
	_drag = PackedFloat32Array(); _drag.resize(cap)
	_shrink = PackedFloat32Array(); _shrink.resize(cap)
	_buf = PackedFloat32Array(); _buf.resize(cap * 16)
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	mm.mesh = q
	mm.instance_count = cap
	mm.visible_instance_count = 0
	node = MultiMeshInstance3D.new()
	node.multimesh = mm
	node.material_override = DmFxTex.material("particle", additive, tex, 5)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = AABB(Vector3(-500, -500, -500), Vector3(1000, 1000, 1000))
	node.visible = false


## o: x y z count color(Color/int) spread speed up life size gravity drag shrink inward (Effects.ts EmitOptions).
func emit(o: Dictionary) -> void:
	var count := int(o.get("count", 0))
	if count <= 0:
		return
	var c := DmFxData.to_color(o.get("color", Color.WHITE)).srgb_to_linear()
	var spread := float(o.get("spread", 0.2))
	var speed := float(o.get("speed", 1.0))
	var up := float(o.get("up", 0.5))
	var life := float(o.get("life", 0.8))
	var size := float(o.get("size", 0.3))
	var gravity := float(o.get("gravity", 0.0))
	var drag := float(o.get("drag", 1.5))
	var shrink := float(o.get("shrink", 1.0))
	var inward: bool = o.get("inward", false)
	var ox := float(o.get("x", 0.0))
	var oy := float(o.get("y", 0.0))
	var oz := float(o.get("z", 0.0))
	for n in count:
		var i := _cursor
		_cursor = (_cursor + 1) % capacity
		if _life[i] <= 0.0:
			_active += 1
			_list.append(i)
		var a := randf() * TAU
		var r := spread * sqrt(randf())
		_pos[i * 3] = ox + cos(a) * r
		_pos[i * 3 + 1] = oy + (randf() - 0.5) * spread * 0.5
		_pos[i * 3 + 2] = oz + sin(a) * r
		var sp := speed * (0.4 + randf() * 0.8)
		var va := (a + PI) if inward else randf() * TAU
		_vel[i * 3] = cos(va) * sp
		_vel[i * 3 + 1] = up * (0.5 + randf())
		_vel[i * 3 + 2] = sin(va) * sp
		var l := life * (0.7 + randf() * 0.6)
		_life[i] = l
		_max_life[i] = l
		_base_size[i] = size * (0.7 + randf() * 0.6)
		_grav[i] = gravity
		_drag[i] = drag
		_shrink[i] = shrink
		_col[i * 3] = c.r
		_col[i * 3 + 1] = c.g
		_col[i * 3 + 2] = c.b
	node.visible = true


func active() -> int:
	return _active


func update(dt: float) -> void:
	if _active == 0:
		node.visible = false
		mm.visible_instance_count = 0
		return
	var n := 0
	var keep := PackedInt32Array()
	keep.resize(_list.size())
	var kept := 0
	for idx in _list.size():
		var i := _list[idx]
		_life[i] -= dt
		if _life[i] <= 0.0:
			_active -= 1
			continue
		keep[kept] = i
		kept += 1
		var t := 1.0 - maxf(0.0, _life[i]) / _max_life[i]
		var k := maxf(0.0, 1.0 - _drag[i] * dt)
		var p3 := i * 3
		_vel[p3] *= k
		_vel[p3 + 1] = _vel[p3 + 1] * k - _grav[i] * dt
		_vel[p3 + 2] *= k
		_pos[p3] += _vel[p3] * dt
		_pos[p3 + 1] += _vel[p3 + 1] * dt
		_pos[p3 + 2] += _vel[p3 + 2] * dt
		var alpha := t / 0.15 if t < 0.15 else 1.0 - (t - 0.15) / 0.85
		var sh := _shrink[i]
		var size := _base_size[i] * ((1.0 - sh * t * 0.7) if sh >= 0.0 else (1.0 + -sh * t))
		if alpha < 0.004:
			continue
		var o := n * 16
		_buf[o] = size
		_buf[o + 1] = 0.0
		_buf[o + 2] = 0.0
		_buf[o + 3] = _pos[p3]
		_buf[o + 4] = 0.0
		_buf[o + 5] = size
		_buf[o + 6] = 0.0
		_buf[o + 7] = _pos[p3 + 1]
		_buf[o + 8] = 0.0
		_buf[o + 9] = 0.0
		_buf[o + 10] = size
		_buf[o + 11] = _pos[p3 + 2]
		_buf[o + 12] = _col[p3]
		_buf[o + 13] = _col[p3 + 1]
		_buf[o + 14] = _col[p3 + 2]
		_buf[o + 15] = alpha
		n += 1
	keep.resize(kept)
	_list = keep
	mm.visible_instance_count = n
	if n > 0:
		mm.buffer = _buf
	node.visible = _active > 0
