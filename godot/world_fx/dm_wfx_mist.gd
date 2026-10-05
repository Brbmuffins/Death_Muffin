class_name DmWfxMist
extends Node3D
## Ground mist (WorldView.buildMist + the "Drift mist" loop in update): 220 big soft smoke puffs at knee height, area-weighted over the
## whole world, each drifting at its own velocity. Exactly the web's CPU rule: a puff more than 45 m (x) / 40 m (z) from the focus is moved
## to focus -+ 44 (x) / 39 (z) on the opposite side, so the far world's puffs pile onto the box edge and the density near the hero is the web's.
## One MultiMesh draw call. The 220-puff loop runs every 4th frame with the accumulated dt (drift is <= 0.35 m/s, i.e. 2 cm per step).
## Puff world diameter = aSize (web gl_PointSize = aSize * scale / depth px); alpha = smoke.a * aAlpha * 1.4, colour 0x3d3350.

const STEP_FRAMES := 4

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D smoke : source_color, filter_linear_mipmap;
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
	vec4 s = texture(smoke, UV);
	ALBEDO = vC;
	ALPHA = s.a * vA * 1.4;
}
"""
static var _shader: Shader

var count := 0
var pos := PackedVector3Array()
var vel := PackedVector2Array()
var mmi: MultiMeshInstance3D
var _mm: MultiMesh
var _acc := 0.0
var _frame := 0

## mist = fx.json "mist".
func setup(mist: Dictionary) -> void:
	name = "Mist"
	count = int(mist.count)
	pos.resize(count)
	vel.resize(count)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	_mm.mesh = q
	_mm.instance_count = count
	_mm.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	var col := DmWfxData.hex(mist.color).srgb_to_linear()
	for i in count:
		pos[i] = Vector3(float(mist.pos[i * 3]), float(mist.pos[i * 3 + 1]), float(mist.pos[i * 3 + 2]))
		vel[i] = Vector2(float(mist.vel[i * 2]), float(mist.vel[i * 2 + 1]))
		_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, pos[i]))
		_mm.set_instance_color(i, col)
		_mm.set_instance_custom_data(i, Color(float(mist.size[i]), float(mist.alpha[i]), 0, 0))
	mmi = MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.render_priority = 4
	m.set_shader_parameter("smoke", DmFxTex.get_tex("smoke"))
	mmi.material_override = m
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 16384.0
	add_child(mmi)

## One web update step with `dt` seconds (WorldView.update "Drift mist").
func step(dt: float, focus: Vector3) -> void:
	for i in count:
		var p := pos[i]
		var v := vel[i]
		p.x += v.x * dt
		p.z += v.y * dt
		if absf(p.x - focus.x) > 45.0:
			p.x = focus.x - signf(p.x - focus.x) * 44.0
		if absf(p.z - focus.z) > 40.0:
			p.z = focus.z - signf(p.z - focus.z) * 39.0
		pos[i] = p
		_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, p))

## Per-frame hook: steps every STEP_FRAMES-th frame with the dt accumulated since the last step.
func tick(dt: float, focus: Vector3) -> void:
	_acc += dt
	_frame += 1
	if _frame % STEP_FRAMES != 1 and _frame > 1:
		return
	step(_acc, focus)
	_acc = 0.0
