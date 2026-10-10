class_name DmFxRing
extends RefCounted
## Port of Effects.ts ParticleSystem: a CPU-simulated ring buffer of motes drawn as one MultiMesh of billboards per blend mode
## (additive "glow" ring of 3500, normal-blend "smoke" ring of 900). Same emit options, same alpha/size curves.
## Upload: the instance buffer is sized to the live motes (instance_count follows them in STEP-sized buckets, with hysteresis) and
## only that slice is sent each frame, not the whole capacity (224 KB for the additive ring). `limit` lowers the ring's usable size
## per graphics preset (DmGraphicsPreset "motes"); motes already flying in slots above a lowered limit finish normally.

var node: MultiMeshInstance3D
var mm: MultiMesh
var capacity: int
var limit: int            ## slots new motes may take (<= capacity); see set_limit
var last_upload_bytes := 0   ## size of the last instance-buffer upload (0 when nothing was sent), for the perf probes

const STEP := 256         ## instance_count granularity
const SHRINK_SLACK := 512 ## the buffer shrinks only when this many instances too large (reallocation is the costly part)

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
var _shown := false


func _init(cap: int, tex: Texture2D, additive: bool) -> void:
	capacity = cap
	limit = cap
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
	mm.instance_count = mini(cap, STEP)
	mm.visible_instance_count = 0
	node = MultiMeshInstance3D.new()
	node.multimesh = mm
	node.material_override = DmFxTex.material("particle", additive, tex, 5)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = AABB(Vector3(-500, -500, -500), Vector3(1000, 1000, 1000))
	node.visible = false


## Usable ring size (clamped to 1..capacity). Takes effect for new motes.
func set_limit(n: int) -> void:
	limit = clampi(n, 1, capacity)
	if _cursor >= limit:
		_cursor = 0


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
		_cursor = (_cursor + 1) % limit
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
	_shown = true


func active() -> int:
	return _active


func update(dt: float) -> void:
	if _active == 0:
		if _shown:   # once, not on every idle frame
			_shown = false
			node.visible = false
			mm.visible_instance_count = 0
		return
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
		var t := 1.0 - life / _max_life[i]
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
	last_upload_bytes = 0
	if n > 0:
		var want := mini(capacity, ((n + STEP - 1) / STEP) * STEP)
		var have := mm.instance_count
		if want > have or have - want > SHRINK_SLACK:
			mm.instance_count = want
			have = want
		mm.visible_instance_count = n
		mm.buffer = _buf if have >= capacity else _buf.slice(0, have * 16)
		last_upload_bytes = have * 64
	else:
		mm.visible_instance_count = 0
	_shown = _active > 0
	node.visible = _shown
