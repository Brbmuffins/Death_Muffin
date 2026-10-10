class_name DmWfxParticles
extends Node3D
## Port of Effects.ts ParticleSystem (CPU ring buffer, one MultiMesh draw call): emit() = ParticleSystem.emit for one particle (spawn
## jitter, speed/life/size randomisation), _update() = ParticleSystem.update line for line (drag, gravity, alpha envelope 0..0.15 in /
## 0.15..1 out, shrink). additive = the web's glow system (AdditiveBlending), else its smoke system (NormalBlending). Size is a world
## diameter (the web's gl_PointSize = size * scale / depth px).

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, %BLEND%, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D map : source_color, filter_linear_mipmap;
varying vec3 vC;
varying float vA;
void vertex() {
	vec3 c = MODEL_MATRIX[3].xyz;
	float size = INSTANCE_CUSTOM.x;
	vec3 wp = c + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * size;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
	vC = COLOR.rgb;
	vA = INSTANCE_CUSTOM.y;
}
void fragment() {
	vec4 t = texture(map, UV);
	if (t.a * vA < 0.004) discard;
	ALBEDO = vC * t.rgb;
	ALPHA = t.a * vA;
}
"""
static var _shaders: Dictionary = {}

var capacity := 160
var rng := RandomNumberGenerator.new()
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _col := PackedColorArray()
var _life := PackedFloat32Array()
var _max_life := PackedFloat32Array()
var _base_size := PackedFloat32Array()
var _grav := PackedFloat32Array()
var _drag := PackedFloat32Array()
var _shrink := PackedFloat32Array()
var _buf := PackedFloat32Array()   # capacity * 20 floats: row-major 3x4 transform (identity basis, position), colour, custom (size, alpha, 0, 0)
var _cursor := 0
var active := 0

const STRIDE := 20

func configure(cap: int, tex: Texture2D, additive: bool, priority: int = 5) -> void:
	capacity = cap
	for a in [_pos, _vel]:
		a.resize(cap)
	_col.resize(cap)
	for a in [_life, _max_life, _base_size, _grav, _drag, _shrink]:
		a.resize(cap)
	_buf.resize(cap * STRIDE)
	for i in cap:   # identity basis once; only position / colour / custom change per frame
		_buf[i * STRIDE] = 1.0
		_buf[i * STRIDE + 5] = 1.0
		_buf[i * STRIDE + 10] = 1.0
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	_mm.mesh = q
	_mm.instance_count = cap
	_mm.visible_instance_count = 0
	_mm.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	var key := "add" if additive else "mix"
	if not _shaders.has(key):
		var sh := Shader.new()
		sh.code = SHADER_CODE.replace("%BLEND%", "blend_add" if additive else "blend_mix")
		_shaders[key] = sh
	var m := ShaderMaterial.new()
	m.shader = _shaders[key]
	m.render_priority = priority
	m.set_shader_parameter("map", tex)
	_mmi.material_override = m
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.extra_cull_margin = 16384.0
	add_child(_mmi)

## Effects.emit for one particle (count 1). `inward` pulls toward the emit point (unused by the world pieces).
func emit(x: float, y: float, z: float, color: Color, spread: float, speed: float, up: float, life: float, size: float, gravity: float = 0.0, drag: float = 1.5, shrink: float = 1.0) -> void:
	var i := _cursor
	_cursor = (_cursor + 1) % capacity
	if _life[i] <= 0.0:
		active += 1
	var a := rng.randf() * TAU
	var r := spread * sqrt(rng.randf())
	_pos[i] = Vector3(x + cos(a) * r, y + (rng.randf() - 0.5) * spread * 0.5, z + sin(a) * r)
	var sp := speed * (0.4 + rng.randf() * 0.8)
	var va := rng.randf() * TAU
	_vel[i] = Vector3(cos(va) * sp, up * (0.5 + rng.randf()), sin(va) * sp)
	var l := life * (0.7 + rng.randf() * 0.6)
	_life[i] = l
	_max_life[i] = l
	_base_size[i] = size * (0.7 + rng.randf() * 0.6)
	_grav[i] = gravity
	_drag[i] = drag
	_shrink[i] = shrink
	_col[i] = color

func _update(dt: float) -> void:
	var n := 0
	if active > 0:
		for i in capacity:
			if _life[i] <= 0.0:
				continue
			_life[i] -= dt
			if _life[i] <= 0.0:
				active -= 1
				continue
			var t := 1.0 - maxf(0.0, _life[i]) / _max_life[i]
			var k := maxf(0.0, 1.0 - _drag[i] * dt)
			var v := _vel[i]
			v.x *= k
			v.y = v.y * k - _grav[i] * dt
			v.z *= k
			_vel[i] = v
			var p := _pos[i] + v * dt
			_pos[i] = p
			var alpha := t / 0.15 if t < 0.15 else 1.0 - (t - 0.15) / 0.85
			var sh := _shrink[i]
			var size := _base_size[i] * (1.0 - sh * t * 0.7 if sh >= 0.0 else 1.0 + -sh * t)
			var o := n * STRIDE
			var c := _col[i]
			_buf[o + 3] = p.x
			_buf[o + 7] = p.y
			_buf[o + 11] = p.z
			_buf[o + 12] = c.r
			_buf[o + 13] = c.g
			_buf[o + 14] = c.b
			_buf[o + 15] = c.a
			_buf[o + 16] = size
			_buf[o + 17] = alpha
			n += 1
	_mm.visible_instance_count = n
	if n > 0:
		_mm.buffer = _buf
	_mmi.visible = n > 0
