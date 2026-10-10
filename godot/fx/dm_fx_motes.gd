class_name DmFxMotes
extends RefCounted
## Billboard motes simulated on the GPU: one MultiMesh, one draw call. The CPU writes a mote once, at spawn (position, velocity,
## gravity, drag, shrink, size, life, spawn time, colour packed into the 16 floats of its instance slot); the vertex shader evaluates
## the whole flight as a closed form of the mote's age, so there is no per-frame loop and the buffer is only re-sent in frames that
## spawned something. Port of Effects.ts ParticleSystem (spawn jitter, alpha 0..0.15 in / 0.15..1 out, shrink 1 - sh*t*0.7 or
## 1 + |sh|*t, velocity *= max(0, 1 - drag*dt) and -= gravity*dt each step, here its continuous limit v = v0 e^(-drag t) - g (1 - e^(-drag t)) / drag).
##
## Slot layout (row-major 3x4 transform + colour, read back in the shader as MODEL_MATRIX columns; the node must sit at the origin):
##   origin = spawn position | col0 = velocity | col1 = (gravity, drag, shrink) | col2 = (base size, life, spawn clock) | colour rgb.

const STEP := 256
const SHRINK_SLACK := 512
const REBASE_AT := 300.0   # seconds of motes' clock after which every spawn stamp is shifted back (keeps float32 stamps exact)
const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, %BLEND%, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D tex : source_color, filter_linear;
uniform float clock;
varying vec3 vC;
varying float vA;
void vertex() {
	vec3 vel = MODEL_MATRIX[0].xyz;
	vec3 gds = MODEL_MATRIX[1].xyz;
	vec3 slf = MODEL_MATRIX[2].xyz;
	float age = clock - slf.z;
	float t = age / slf.y;
	if (t >= 1.0 || t < 0.0) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
		vC = vec3(0.0);
		vA = 0.0;
	} else {
		float d = gds.y;
		float dv = d > 0.001 ? (1.0 - exp(-d * age)) / d : age - 0.5 * d * age * age;
		float gv = d > 0.001 ? (age - dv) / d : 0.5 * age * age;
		vec3 c = MODEL_MATRIX[3].xyz + vel * dv - vec3(0.0, gds.x * gv, 0.0);
		float sh = gds.z;
		float size = slf.x * (sh >= 0.0 ? 1.0 - sh * t * 0.7 : 1.0 - sh * t);
		vA = t < 0.15 ? t / 0.15 : 1.0 - (t - 0.15) / 0.85;
		vC = COLOR.rgb;
		vec3 wp = c + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * size;
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
	}
}
void fragment() {
	vec4 s = texture(tex, UV);
	float a = s.a * vA;
	if (a < 0.004) discard;
	ALBEDO = vC * s.rgb;
	ALPHA = a;
}
"""
static var _shaders: Dictionary = {}

var node: MultiMeshInstance3D
var mm: MultiMesh
var capacity: int

var _mat: ShaderMaterial
var _buf: PackedFloat32Array     # capacity * 16 floats, the instance buffer
var _death: PackedFloat32Array   # per slot: clock at which the mote ends
var limit: int
var last_upload_bytes := 0
var _cursor := 0
var _high := 0                   # slots [0, _high) may hold live motes
var _clock := 0.0
var _last_death := 0.0           # latest end among everything spawned since the last idle
var _dirty := false
var _shown := false


func _init(cap: int, tex: Texture2D, additive: bool, priority: int = 5) -> void:
	capacity = cap
	limit = cap
	_buf = PackedFloat32Array()
	_buf.resize(cap * 16)
	_death = PackedFloat32Array()
	_death.resize(cap)
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	mm.mesh = q
	mm.instance_count = mini(cap, STEP)
	mm.visible_instance_count = 0
	mm.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	var key := "add" if additive else "mix"
	if not _shaders.has(key):
		var sh := Shader.new()
		sh.code = SHADER_CODE.replace("%BLEND%", "blend_add" if additive else "blend_mix")
		_shaders[key] = sh
	_mat = ShaderMaterial.new()
	_mat.shader = _shaders[key]
	_mat.render_priority = priority
	_mat.set_shader_parameter("tex", tex)
	node = MultiMeshInstance3D.new()
	node.multimesh = mm
	node.material_override = _mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.extra_cull_margin = 16384.0
	node.top_level = true   # the packed basis is data, not a transform: the node transform has to stay the identity
	node.visible = false


## Usable ring size (clamped to 1..capacity), for new motes.
func set_limit(n: int) -> void:
	limit = clampi(n, 1, capacity)
	if _cursor >= limit:
		_cursor = 0


## One mote (Effects.emit, count 1), random draws in DmFxRing's old order. Colour is sRGB as given: the Compatibility renderer linearises
## MultiMesh instance colours itself.
func spawn(x: float, y: float, z: float, c: Color, spread: float, speed: float, up: float, life: float, size: float, gravity: float, drag: float, shrink: float, inward: bool = false) -> void:
	var i := _cursor
	_cursor = (_cursor + 1) % limit
	if i >= _high:
		_high = i + 1
	var a := randf() * TAU
	var r := spread * sqrt(randf())
	var py := y + (randf() - 0.5) * spread * 0.5
	var sp := speed * (0.4 + randf() * 0.8)
	var va := (a + PI) if inward else randf() * TAU
	var vy := up * (0.5 + randf())
	var l := life * (0.7 + randf() * 0.6)
	var sz := size * (0.7 + randf() * 0.6)
	var o := i * 16
	var b := _buf
	b[o] = cos(va) * sp
	b[o + 1] = gravity
	b[o + 2] = sz
	b[o + 3] = x + cos(a) * r
	b[o + 4] = vy
	b[o + 5] = drag
	b[o + 6] = l
	b[o + 7] = py
	b[o + 8] = sin(va) * sp
	b[o + 9] = shrink
	b[o + 10] = _clock
	b[o + 11] = z + sin(a) * r
	b[o + 12] = c.r
	b[o + 13] = c.g
	b[o + 14] = c.b
	b[o + 15] = 1.0
	var death := _clock + l
	_death[i] = death
	if death > _last_death:
		_last_death = death
	_dirty = true
	if not _shown:
		_shown = true
		node.visible = true


## Motes still alive (scans the slots: for tests and the profiler, not for per-frame use).
func active() -> int:
	var n := 0
	for i in _high:
		if _death[i] > _clock:
			n += 1
	return n


## Advance the motes' clock. Costs a clock uniform and, only in frames that spawned, one upload of the slots in use; nothing when idle.
func update(dt: float) -> void:
	last_upload_bytes = 0
	if not _shown:
		return
	_clock += dt
	if _clock >= _last_death:
		_idle()
		return
	if _clock > REBASE_AT:
		_rebase()
	if _dirty:
		_dirty = false
		var want := mini(capacity, ((_high + STEP - 1) / STEP) * STEP)
		var have := mm.instance_count
		if want > have or have - want > SHRINK_SLACK:
			mm.instance_count = want
			have = want
		mm.visible_instance_count = _high
		mm.buffer = _buf if have >= capacity else _buf.slice(0, have * 16)
		last_upload_bytes = have * 64
	_mat.set_shader_parameter("clock", _clock)


## Every mote is dead: hide the node and restart the ring and the clock. Slots at or above the restarted `_high` are never drawn, and
## the ring refills from slot 0 upwards, so a stale slot is always overwritten before it is shown again.
func _idle() -> void:
	_shown = false
	node.visible = false
	mm.visible_instance_count = 0
	_cursor = 0
	_high = 0
	_dirty = false
	_last_death = 0.0
	_clock = 0.0
	_mat.set_shader_parameter("clock", 0.0)


func _rebase() -> void:
	for i in _high:
		_buf[i * 16 + 10] -= _clock
		_death[i] -= _clock
	_last_death -= _clock
	_clock = 0.0
	_dirty = true
