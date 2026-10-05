class_name DmWfxWater
extends Node3D
## Standing water (src/graphics/Water.ts): the flooded Drowned Nave, the Fen bog, the Acre pond and the graveyard's rain puddles, merged into
## ONE mesh (one draw call). Every vertex carries its distance to the shore (UV.x) and a sheen (UV.y), so the shader fades the rim, deepens
## the middle and never does a per-pixel rect test. High quality: two scrolling procedural normal maps, fresnel, a moon glint and up to 16
## ripple rings; low quality is a flat glossy sheet. Rect/puddle geometry, ripple maths and every constant are the web's.
##   add_ripple(x, z, strength)   ring from (x, z); ignored on dry ground, the oldest ring is recycled
##   is_wet(x, z)                 the nave's flood / a bog / a puddle
##   set_palette(fen) / set_moon(color)

const RIPPLES := 16
const RIPPLE_LIFE := 2.2
const DEPTH_INSET := 3.2
const Y := 0.06
const NAVE_SHEEN := 0.25

const SHADER_CODE := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;
uniform sampler2D normals : filter_linear_mipmap, repeat_enable;
uniform vec4 ripples[16];
uniform vec3 base_color : source_color = vec3(0.08, 0.07, 0.16);
uniform vec3 deep : source_color = vec3(0.016, 0.016, 0.043);
uniform vec3 rim : source_color = vec3(0.17, 0.23, 0.48);
uniform vec3 moon : source_color = vec3(0.56, 0.53, 0.85);
uniform float t;
varying float vEdge;
varying float vSheen;
varying vec3 vW;
void vertex() {
	vEdge = UV.x;
	vSheen = UV.y;
	vW = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 wp = vW.xz;
	vec3 na = texture(normals, wp * 0.085 + vec2(t * 0.012, t * 0.006)).xyz * 2.0 - 1.0;
	vec3 nb = texture(normals, vec2(wp.y, -wp.x) * 0.21 + vec2(-t * 0.019, t * 0.015)).xyz * 2.0 - 1.0;
	vec2 slope = na.xy * 0.08 + nb.xy * 0.12;
	vec2 fine = (texture(normals, wp * 0.63 + vec2(t * 0.05, -t * 0.035)).xy * 2.0 - 1.0) * 0.15;
	float rippleLight = 0.0;
	for (int i = 0; i < 16; i++) {
		vec4 rp = ripples[i];
		float age = t - rp.z;
		if (rp.w <= 0.0 || age < 0.0 || age > 2.2) continue;
		vec2 d = wp - rp.xy;
		float dist = length(d);
		float x = dist - age * 1.5;
		float env = exp(-x * x * 5.0) * (1.0 - age / 2.2) * rp.w;
		float w = cos(x * 13.0) * env;
		slope += (d / max(dist, 0.001)) * w * 0.32;
		rippleLight += env * max(0.0, w);
	}
	vec3 wn = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	vec3 V = normalize(CAMERA_POSITION_WORLD - vW);
	float fres = pow(1.0 - clamp(dot(V, wn), 0.0, 1.0), 3.0);
	float depth = smoothstep(0.15, 3.2, vEdge);
	vec3 R = reflect(-V, normalize(wn + vec3(-fine.x, 0.0, -fine.y)));
	float patchy = smoothstep(0.1, 0.7, texture(normals, wp * 0.021 + t * 0.004).x);
	float glint = pow(max(dot(R, normalize(vec3(0.12, 0.42, -0.9))), 0.0), 220.0) * patchy;
	ALBEDO = mix(base_color, deep, depth * 0.6);
	ROUGHNESS = 0.16;
	METALLIC = 0.1;
	EMISSION = rim * (fres * 0.6 + rippleLight * 0.3) + moon * glint * 0.6 * mix(0.3, 1.0, smoothstep(0.25, 1.0, vSheen)) + moon * vSheen * (0.025 + 0.05 * patchy + 0.2 * fres);
	ALPHA = smoothstep(0.0, 0.45, vEdge) * mix(0.5, 0.86, depth);
}
"""
static var _shader: Shader
static var _normals: ImageTexture

var rects: Array = []
var puddles: Array = []
var mesh_instance: MeshInstance3D
var quality := "high"
var time := 0.0
var _next := 0
var _ripples := PackedVector4Array()
var _high: ShaderMaterial
var _low: StandardMaterial3D
var tri_count := 0

func setup(rect_list: Array, puddle_list: Array) -> void:
	rects = rect_list
	puddles = puddle_list
	name = "Water"
	_ripples.resize(RIPPLES)
	for i in RIPPLES:
		_ripples[i] = Vector4(0, 0, -99, 0)
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	_high = ShaderMaterial.new()
	_high.shader = _shader
	_high.render_priority = -1   # under spell decals, like renderOrder 1
	_high.set_shader_parameter("ripples", _ripples)
	_high.set_shader_parameter("t", 0.0)
	_low = StandardMaterial3D.new()
	_low.albedo_color = Color(DmWfxData.hex(0x131228), 0.72)
	_low.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_low.roughness = 0.2
	_low.metallic = 0.1
	_low.cull_mode = BaseMaterial3D.CULL_DISABLED
	_low.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_low.render_priority = -1
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "WaterMesh"
	mesh_instance.mesh = build_mesh()
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)
	set_palette(false)
	set_quality("high")

func set_quality(q: String) -> void:
	quality = q
	if q == "high":
		_high.set_shader_parameter("normals", normals_texture())
		mesh_instance.material_override = _high
	else:
		mesh_instance.material_override = _low

## The nave's violet-black vs the Fen's teal-black.
func set_palette(fen: bool) -> void:
	_high.set_shader_parameter("deep", DmWfxData.hex(0x02100e if fen else 0x04040b))
	_high.set_shader_parameter("rim", DmWfxData.hex(0x2a7a72 if fen else 0x2c3a7a))
	_high.set_shader_parameter("base_color", DmWfxData.hex(0x0f2a2a if fen else 0x15142a))
	_low.albedo_color = Color(DmWfxData.hex(0x0d2426 if fen else 0x131228), 0.72)

func set_moon(c: Color) -> void:
	_high.set_shader_parameter("moon", c)

func tick(dt: float) -> void:
	time += dt
	_high.set_shader_parameter("t", time)

func is_wet(x: float, z: float) -> bool:
	for r in rects:
		if x >= float(r.x0) and x <= float(r.x1) and z >= float(r.z0) and z <= float(r.z1):
			return true
	for p in puddles:
		var dx := x - float(p.x)
		var dz := z - float(p.z)
		var c := cos(float(p.rot))
		var s := sin(float(p.rot))
		var lx := (dx * c + dz * s) / (float(p.r) * float(p.sx))
		var lz := (-dx * s + dz * c) / float(p.r)
		if lx * lx + lz * lz <= 1.0:
			return true
	return false

func add_ripple(x: float, z: float, strength: float = 1.0) -> bool:
	if not is_wet(x, z):
		return false
	_ripples[_next] = Vector4(x, z, time, strength)
	_next = (_next + 1) % RIPPLES
	_high.set_shader_parameter("ripples", _ripples)
	return true

func active_ripples() -> int:
	var n := 0
	for r in _ripples:
		if r.w > 0.0 and time - r.z <= RIPPLE_LIFE:
			n += 1
	return n

# ------------------------------------------------------------------ geometry (Water.ts rectGeometry / puddleGeometry)
func build_mesh() -> ArrayMesh:
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for r in rects:
		var inset := minf(DEPTH_INSET, minf((float(r.x1) - float(r.x0)) / 2.0 - 0.01, (float(r.z1) - float(r.z0)) / 2.0 - 0.01))
		var base := pos.size()
		var outer := [[r.x0, r.z0], [r.x1, r.z0], [r.x1, r.z1], [r.x0, r.z1]]
		var inner := [[float(r.x0) + inset, float(r.z0) + inset], [float(r.x1) - inset, float(r.z0) + inset], [float(r.x1) - inset, float(r.z1) - inset], [float(r.x0) + inset, float(r.z1) - inset]]
		for o in outer:
			pos.append(Vector3(float(o[0]), Y, float(o[1])))
			uv.append(Vector2(0.0, NAVE_SHEEN))
		for i in inner:
			pos.append(Vector3(float(i[0]), Y, float(i[1])))
			uv.append(Vector2(inset, NAVE_SHEEN))
		for k in 4:
			var n := (k + 1) % 4
			idx.append_array([base + k, base + 4 + k, base + n, base + n, base + 4 + k, base + 4 + n])
		idx.append_array([base + 4, base + 7, base + 5, base + 5, base + 7, base + 6])
	for p in puddles:
		var seg := 18
		var base := pos.size()
		pos.append(Vector3(float(p.x), Y - 0.02, float(p.z)))
		uv.append(Vector2(float(p.r), 1.0))
		var c := cos(float(p.rot))
		var s := sin(float(p.rot))
		for k in seg:
			var a := float(k) / float(seg) * TAU
			var wob := 1.0 + 0.12 * sin(a * 3.0 + float(p.x)) + 0.07 * sin(a * 5.0 + float(p.z))
			var lx := cos(a) * float(p.r) * float(p.sx) * wob
			var lz := sin(a) * float(p.r) * wob
			pos.append(Vector3(float(p.x) + lx * c - lz * s, Y - 0.02, float(p.z) + lx * s + lz * c))
			uv.append(Vector2(0.0, 1.0))
		for k in seg:
			idx.append_array([base, base + 1 + ((k + 1) % seg), base + 1 + k])
	tri_count = idx.size() / 3
	var mesh := ArrayMesh.new()
	if pos.is_empty():
		return mesh
	var norms := PackedVector3Array()
	norms.resize(pos.size())
	norms.fill(Vector3.UP)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

## Tileable ripple normals (Water.ts waterNormals): seven integer-frequency waves so the height field is seamless.
static func normals_texture() -> ImageTexture:
	if _normals != null:
		return _normals
	var size := 256
	var waves := [[1, 2, 0.9, 0.3], [3, -1, 0.6, 1.7], [-2, 3, 0.45, 4.1], [5, 2, 0.28, 2.2], [-4, -5, 0.2, 5.3], [7, -3, 0.14, 0.8], [2, 9, 0.1, 3.6]]
	# cos(TAU(a u + b v) + ph) = cos(A)cos(B) - sin(A)sin(B), A = TAU a u + ph, B = TAU b v: per-column / per-row tables.
	var cx: Array = []
	var sx: Array = []
	var cy: Array = []
	var sy: Array = []
	for w in waves:
		var a1 := PackedFloat32Array()
		var a2 := PackedFloat32Array()
		var b1 := PackedFloat32Array()
		var b2 := PackedFloat32Array()
		for i in size:
			var u := float(i) / size
			a1.append(cos(TAU * float(w[0]) * u + float(w[3])))
			a2.append(sin(TAU * float(w[0]) * u + float(w[3])))
			b1.append(cos(TAU * float(w[1]) * u))
			b2.append(sin(TAU * float(w[1]) * u))
		cx.append(a1)
		sx.append(a2)
		cy.append(b1)
		sy.append(b2)
	var data := PackedByteArray()
	data.resize(size * size * 3)
	var s := 0.045
	for y in size:
		for x in size:
			var dx := 0.0
			var dy := 0.0
			for k in 7:
				var w: Array = waves[k]
				var c: float = (float(cx[k][x]) * float(cy[k][y]) - float(sx[k][x]) * float(sy[k][y])) * float(w[2]) * TAU
				dx += c * float(w[0])
				dy += c * float(w[1])
			var n := Vector3(-dx * s, -dy * s, 1.0).normalized()
			var i := (y * size + x) * 3
			data[i] = int(clampf((n.x * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			data[i + 1] = int(clampf((n.y * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			data[i + 2] = int(clampf((n.z * 0.5 + 0.5) * 255.0, 0.0, 255.0))
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RGB8, data)
	img.generate_mipmaps()
	_normals = ImageTexture.create_from_image(img)
	return _normals
