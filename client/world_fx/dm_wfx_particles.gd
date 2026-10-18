class_name DmWfxParticles
extends Node3D
## Effects.ts ParticleSystem as a ring of emission records that the vertex shader draws. The old game's
## GDScript stepped every live particle every frame (drag, gravity, the alpha envelope and the shrink, three RenderingServer calls a particle); here the CPU writes a particle ONCE,
## when it is emitted, and the shader works out its place, size and fade from its age: the same laws in closed form (the web's Euler step with drag d is v(t) = v0 e^-dt, and y also
## falls with the gravity g: p(t) = p0 + (v0 + g/d)(1 - e^-dt)/d - g t/d). The record lives in the instance: the transform's origin is the spawn point and its basis holds the launch
## velocity (x) and gravity, drag and shrink (y); the instance colour is the sRGB colour; the custom data is (birth, life, size). `t` is the dressing's clock, set once a frame
## while anything is alive. The additive system only (the web's NormalBlending smoke system has no user in the world dressing). One draw call.

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D map : source_color, filter_linear_mipmap;
uniform float t;
varying vec3 vC;
varying float vA;
// The instance colour is an sRGB value (a hex colour): Compatibility converts what a shader writes to ALBEDO from sRGB, Forward+ does not (client/README.md "Graphics presets").
vec3 dm_srgb(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c * 0.0773993808, lessThan(c, vec3(0.04045)));
}
void vertex() {
	float age = t - INSTANCE_CUSTOM.x;
	float u = age / INSTANCE_CUSTOM.y;
	vec3 v0 = MODEL_MATRIX[0].xyz;
	float g = MODEL_MATRIX[1].x;
	float d = max(MODEL_MATRIX[1].y, 0.001);
	float sh = MODEL_MATRIX[1].z;
	float k = (1.0 - exp(-d * age)) / d;
	vec3 c = MODEL_MATRIX[3].xyz + vec3(v0.x * k, (v0.y + g / d) * k - g / d * age, v0.z * k);
	float size = INSTANCE_CUSTOM.z * (sh >= 0.0 ? 1.0 - sh * u * 0.7 : 1.0 - sh * u);
	vec3 wp = c + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * size;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
	if (age < 0.0 || u >= 1.0) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);   // dead (or not born): outside the clip volume, nothing is drawn
	}
	vC = dm_srgb(COLOR.rgb);
	vA = u < 0.15 ? u / 0.15 : 1.0 - (u - 0.15) / 0.85;
}
void fragment() {
	vec4 t4 = texture(map, UV);
	if (t4.a * vA < 0.004) discard;
	ALBEDO = vC * t4.rgb;
	ALPHA = t4.a * vA;
}
"""
static var _shader: Shader

var capacity := 160
var rng := RandomNumberGenerator.new()
var clock := 0.0                 ## the dressing's clock, seconds (the shader's `t`)
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _mat: ShaderMaterial
var emitted := 0                 ## particles emitted so far (the tests count them)
var _cursor := 0
var _alive_until := -1.0         ## the clock at which the last emitted particle dies


func configure(cap: int, tex: Texture2D, priority: int = 5) -> void:
	capacity = cap
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	_mm.mesh = q
	_mm.instance_count = cap
	_mm.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	for i in cap:
		_mm.set_instance_custom_data(i, Color(-1.0e6, 1.0, 0.0, 0.0))   # born long ago: dead
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Ring"
	_mmi.multimesh = _mm
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_mat.render_priority = priority
	_mat.set_shader_parameter("map", tex)
	_mmi.material_override = _mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.extra_cull_margin = 16384.0
	_mmi.visible = false
	add_child(_mmi)


## Effects.emit for one particle (count 1), born `ago` seconds ago: the spawn point, launch velocity, life and size are drawn as the web draws them, and the particle is
## written into the ring (the oldest record goes when it is full). It is drawn from the next frame on.
func emit(x: float, y: float, z: float, color: Color, spread: float, speed: float, up: float, life: float, size: float, gravity: float = 0.0, drag: float = 1.5, shrink: float = 1.0, ago: float = 0.0) -> void:
	var i := _cursor
	_cursor = (_cursor + 1) % capacity
	emitted += 1
	var a := rng.randf() * TAU
	var r := spread * sqrt(rng.randf())
	var at := Vector3(x + cos(a) * r, y + (rng.randf() - 0.5) * spread * 0.5, z + sin(a) * r)
	var sp := speed * (0.4 + rng.randf() * 0.8)
	var va := rng.randf() * TAU
	var v := Vector3(cos(va) * sp, up * (0.5 + rng.randf()), sin(va) * sp)
	var l := life * (0.7 + rng.randf() * 0.6)
	var birth := clock - ago
	_mm.set_instance_transform(i, Transform3D(Basis(v, Vector3(gravity, drag, shrink), Vector3.ZERO), at))
	_mm.set_instance_color(i, color)
	_mm.set_instance_custom_data(i, Color(birth, l, size * (0.7 + rng.randf() * 0.6), 0.0))
	_alive_until = maxf(_alive_until, birth + l)
	if not _mmi.visible:
		_mmi.visible = true
		_mat.set_shader_parameter("t", clock)


## The clock advances by `dt`: the shader's `t` follows while anything is alive, and the draw is dropped when the last particle has died.
func advance(dt: float) -> void:
	clock += dt
	if not _mmi.visible:
		return
	if clock >= _alive_until:
		_mmi.visible = false
		return
	_mat.set_shader_parameter("t", clock)


## Whether the ring has anything to draw.
func drawing() -> bool:
	return _mmi != null and _mmi.visible


## One particle at `age` seconds, worked out on the CPU with the shader's formulas: the place, the size and the alpha. `rec` = {at, v, g, d, shrink, life, size}. The test holds this against
## the web's per-frame Euler step (tests/dressing.gd); the shader is this function in GLSL.
static func pose(rec: Dictionary, age: float) -> Dictionary:
	var life: float = rec["life"]
	var u := age / life
	var v0: Vector3 = rec["v"]
	var g: float = rec["g"]
	var d := maxf(float(rec["d"]), 0.001)
	var sh: float = rec["shrink"]
	var k := (1.0 - exp(-d * age)) / d
	var at: Vector3 = rec["at"]
	var p := at + Vector3(v0.x * k, (v0.y + g / d) * k - g / d * age, v0.z * k)
	var size: float = float(rec["size"]) * (1.0 - sh * u * 0.7 if sh >= 0.0 else 1.0 - sh * u)
	var alpha := u / 0.15 if u < 0.15 else 1.0 - (u - 0.15) / 0.85
	return {"pos": p, "size": size, "alpha": alpha}
