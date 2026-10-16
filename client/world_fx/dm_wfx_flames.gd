class_name DmWfxFlames
extends RefCounted
## Candle-flame sprites (WorldView.buildFlameData/buildFlames + FLAME_VS/FS): one additive billboard per flame, flickering and bobbing in
## the vertex shader. One MultiMesh per area (347 flames over 8 areas), child of the area node so it is hidden/streamed with it and
## frustum-culled by a padded area box (the web's per-area bounding sphere + 3). Sanctum candle groups gutter out via set_group_lit().
## Size: the web's gl_PointSize = 0.24 * f * lit * scale / depth px is exactly a world-space diameter of 0.24 * f * lit.

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D map : source_color, filter_linear_mipmap;
varying float vA;
void vertex() {
	float ph = INSTANCE_CUSTOM.x;
	float lit = INSTANCE_CUSTOM.y;
	float f = 0.82 + 0.18 * sin(TIME * 13.0 + ph * 7.0) * sin(TIME * 7.3 + ph * 3.0);
	vec3 c = MODEL_MATRIX[3].xyz;
	c.y += 0.02 * sin(TIME * 9.0 + ph);
	float size = 0.24 * f * lit;
	vec3 wp = c + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * size;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
	vA = f * lit;
}
void fragment() {
	vec4 t = texture(map, UV);
	vec3 c = mix(vec3(1.0, 0.55, 0.25), vec3(1.0, 0.92, 0.75), t.r);
	ALBEDO = c * 1.35;
	ALPHA = t.a * vA;
}
"""
static var _shader: Shader

static func material() -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("map", DmFxTex.get_tex("glow"))
	return m

## d = {pos: flat [x,y,z,...], phase: [], groups: []}; lit_off = {group: true} for groups already out.
static func build(parent: Node3D, area: String, d: Dictionary, lit_off: Dictionary = {}) -> MultiMeshInstance3D:
	var n: int = (d.phase as Array).size()
	if n == 0:
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	mm.mesh = q
	mm.instance_count = n
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var pos: Array = d.pos
	var lits := PackedFloat32Array()
	lits.resize(n)
	for i in n:
		var p := Vector3(float(pos[i * 3]), float(pos[i * 3 + 1]), float(pos[i * 3 + 2]))
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, p))
		var g: Variant = (d.groups as Array)[i]
		var lit := 0.0 if (g != null and lit_off.has(str(g))) else 1.0
		lits[i] = lit
		mm.set_instance_custom_data(i, Color(float((d.phase as Array)[i]), lit, 0, 0))
		lo = lo.min(p)
		hi = hi.max(p)
	var pad := Vector3(3, 3, 3)
	mm.custom_aabb = AABB(lo - pad, (hi - lo) + pad * 2.0)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Flames_%s" % area
	mmi.multimesh = mm
	mmi.material_override = material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.set_meta("groups", d.groups)
	mmi.set_meta("phase", d.phase)
	mmi.set_meta("lit", lits)   # mirror of the per-instance lit flag (custom data is write-only on a dummy renderer)
	parent.add_child(mmi)
	return mmi

static func set_group_lit(mmi: MultiMeshInstance3D, group: String, lit: bool) -> void:
	var groups: Array = mmi.get_meta("groups")
	var mm := mmi.multimesh
	for i in groups.size():
		if groups[i] != null and str(groups[i]) == group:
			var lits: PackedFloat32Array = mmi.get_meta("lit")
			lits[i] = 1.0 if lit else 0.0
			mmi.set_meta("lit", lits)
			mm.set_instance_custom_data(i, Color(float(mmi.get_meta("phase")[i]), lits[i], 0, 0))
