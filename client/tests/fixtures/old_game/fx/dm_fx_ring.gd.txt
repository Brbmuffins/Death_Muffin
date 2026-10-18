class_name DmFxRing
extends RefCounted
## Port of Effects.ts ParticleSystem: a CPU-simulated ring buffer of motes drawn as one MultiMesh of billboards per blend mode
## (additive "glow" ring of 3500, normal-blend "smoke" ring of 900). Same emit options, same alpha/size curves.

## While at most SMALL_CAP motes are live only a small MultiMesh is drawn and uploaded (a full-ring buffer is 224 KB for the additive ring, and
## `MultiMesh.buffer` must always be the whole buffer). Both MultiMeshes are allocated once here and never resized; only visibility switches.
const SMALL_CAP := 256

var node: MultiMeshInstance3D        # full-size ring
var mm: MultiMesh
var node_small: MultiMeshInstance3D  # SMALL_CAP ring, sibling of `node` (visibility is not inherited)
var mm_small: MultiMesh
var capacity: int

var _pos: PackedFloat32Array
var _vel: PackedFloat32Array
var _col: PackedFloat32Array
var _life: PackedFloat32Array
var _inv_life: PackedFloat32Array   # 1 / the mote's full life
var _base_size: PackedFloat32Array
var _grav: PackedFloat32Array
var _drag: PackedFloat32Array
var _shrink: PackedFloat32Array
var _buf: PackedFloat32Array        # the buffer update() is writing (swapped with _buf_other while the small ring is the one drawn)
var _buf_other: PackedFloat32Array
var _cursor := 0
var _active := 0
var _list: PackedInt32Array = PackedInt32Array()  # indices of live motes
var _shown := false
var _mode := 0   # 0 neither ring shown yet, 1 full ring, 2 small ring


func _init(cap: int, tex: Texture2D, additive: bool) -> void:
	capacity = cap
	_pos = PackedFloat32Array(); _pos.resize(cap * 3)
	_vel = PackedFloat32Array(); _vel.resize(cap * 3)
	_col = PackedFloat32Array(); _col.resize(cap * 3)
	_life = PackedFloat32Array(); _life.resize(cap)
	_inv_life = PackedFloat32Array(); _inv_life.resize(cap)
	_base_size = PackedFloat32Array(); _base_size.resize(cap)
	_grav = PackedFloat32Array(); _grav.resize(cap)
	_drag = PackedFloat32Array(); _drag.resize(cap)
	_shrink = PackedFloat32Array(); _shrink.resize(cap)
	_buf = PackedFloat32Array(); _buf.resize(cap * 16)
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	var mat := DmFxTex.material("particle", additive, tex, 5)
	mm = _make_mm(q, cap)
	node = _make_node(mm, mat)
	if cap > SMALL_CAP:
		_buf_other = PackedFloat32Array(); _buf_other.resize(SMALL_CAP * 16)
		mm_small = _make_mm(q, SMALL_CAP)
		node_small = _make_node(mm_small, mat)


static func _make_mm(q: Mesh, cap: int) -> MultiMesh:
	var m := MultiMesh.new()
	m.transform_format = MultiMesh.TRANSFORM_3D
	m.use_colors = true
	m.mesh = q
	m.instance_count = cap
	m.visible_instance_count = 0
	return m


static func _make_node(m: MultiMesh, mat: Material) -> MultiMeshInstance3D:
	var nd := MultiMeshInstance3D.new()
	nd.multimesh = m
	nd.material_override = mat
	nd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	nd.custom_aabb = AABB(Vector3(-500, -500, -500), Vector3(1000, 1000, 1000))
	nd.visible = false
	return nd


## o: x y z count color(Color/int) spread speed up life size gravity drag shrink inward (Effects.ts EmitOptions).
func emit(o: Dictionary) -> void:
	var count := int(o.get("count", 0))
	if count <= 0:
		return
	# sRGB as given: the Compatibility renderer linearises MultiMesh instance colours itself (converting here too drew every mote
	# ~3x too dark and dark ones pure black, e.g. the Grave Surge's crypt dust).
	var c := DmFxData.to_color(o.get("color", Color.WHITE))
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
		_inv_life[i] = 1.0 / l
		_base_size[i] = size * (0.7 + randf() * 0.6)
		_grav[i] = gravity
		_drag[i] = drag
		_shrink[i] = shrink
		_col[i * 3] = c.r
		_col[i * 3 + 1] = c.g
		_col[i * 3 + 2] = c.b
	_shown = true   # update() picks which of the two rings is visible


func active() -> int:
	return _active


func update(dt: float) -> void:
	if _active == 0:
		if _shown:   # once, not on every idle frame
			_shown = false
			_mode = 0
			node.visible = false
			mm.visible_instance_count = 0
			if node_small != null:
				node_small.visible = false
				mm_small.visible_instance_count = 0
		return
	# _active bounds the packed count n, so a small ring is safe whenever it fits.
	var small := node_small != null and _active <= SMALL_CAP
	if small:
		var tmp := _buf
		_buf = _buf_other
		_buf_other = tmp
	var n := 0
	var kept := 0
	for idx in _list.size():
		var i := _list[idx]
		var life := _life[i] - dt
		_life[i] = life
		if life <= 0.0:
			_active -= 1
			continue
		_list[kept] = i   # compacted in place (the live list used to be rebuilt into a fresh array every frame)
		kept += 1
		var t := 1.0 - life * _inv_life[i]
		var k := maxf(0.0, 1.0 - _drag[i] * dt)
		var p3 := i * 3
		var vx := _vel[p3] * k
		var vy := _vel[p3 + 1] * k - _grav[i] * dt
		var vz := _vel[p3 + 2] * k
		_vel[p3] = vx
		_vel[p3 + 1] = vy
		_vel[p3 + 2] = vz
		var px := _pos[p3] + vx * dt
		var py := _pos[p3 + 1] + vy * dt
		var pz := _pos[p3 + 2] + vz * dt
		_pos[p3] = px
		_pos[p3 + 1] = py
		_pos[p3 + 2] = pz
		var alpha := t / 0.15 if t < 0.15 else 1.0 - (t - 0.15) / 0.85
		var sh := _shrink[i]
		var size := _base_size[i] * ((1.0 - sh * t * 0.7) if sh >= 0.0 else (1.0 + -sh * t))
		if alpha < 0.004:
			continue
		# Row-major 3x4 transform + colour. The off-diagonal slots (1, 2, 4, 6, 8, 9) are always 0 and `_buf` starts zeroed, so they are
		# never rewritten (6 of the 16 stores per mote).
		var o := n * 16
		_buf[o] = size
		_buf[o + 3] = px
		_buf[o + 5] = size
		_buf[o + 7] = py
		_buf[o + 10] = size
		_buf[o + 11] = pz
		_buf[o + 12] = _col[p3]
		_buf[o + 13] = _col[p3 + 1]
		_buf[o + 14] = _col[p3 + 2]
		_buf[o + 15] = alpha
		n += 1
	_list.resize(kept)
	_shown = _active > 0
	var mode := 2 if small else 1
	if mode != _mode:   # switching rings: the other one stops drawing (once, not every frame)
		_mode = mode
		node.visible = not small
		mm.visible_instance_count = 0
		if node_small != null:
			node_small.visible = small
			mm_small.visible_instance_count = 0
	var draw_mm := mm_small if small else mm
	draw_mm.visible_instance_count = n
	if n > 0:
		draw_mm.buffer = _buf
	if small:
		var tmp2 := _buf
		_buf = _buf_other
		_buf_other = tmp2
