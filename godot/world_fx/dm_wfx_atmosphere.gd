class_name DmWfxAtmosphere
extends Node3D
## Per-area weather around the camera focus (src/graphics/Atmosphere.ts): ash and leaves over the Hollow Graves, bone-dust in the Ossuary,
## drips and faint rain in the Drowned Nave, rising embers in the Bell Sanctum, ... One mesh = one draw call; every particle moves in the
## vertex shader from a seed + time and wraps around the focus. The CPU only touches the mesh when the area changes (cross-fade 1.6/s out,
## 0.8/s in, like the web). Profiles are in data/world_fx/fx.json; per-particle seeds replay the web's
## mulberry32(area.length * 977 + charCode(area[0])) call order exactly.

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D atlas : source_color, filter_linear;
uniform float t;
uniform float fade;
uniform vec3 focus;
uniform vec3 box;
varying vec4 vLook;
varying vec3 vColor;
varying float vA;
varying float vRot;
void vertex() {
	vec4 aSeed = CUSTOM0;
	vec4 aMotion = CUSTOM1;
	vec4 aLook = CUSTOM2;
	vec3 p = aSeed.xyz + aMotion.xyz * t;
	p.x += sin(t * 0.9 + aSeed.w * 6.2831) * aMotion.w;
	p.z += cos(t * 0.7 + aSeed.w * 4.1) * aMotion.w * 0.6;
	vec3 rel = vec3(
		mod(p.x - focus.x + box.x, 2.0 * box.x) - box.x,
		mod(p.y, box.y),
		mod(p.z - focus.z + box.z, 2.0 * box.z) - box.z);
	vec3 wp = vec3(focus.x + rel.x, rel.y, focus.z + rel.z);
	float fy = smoothstep(0.0, 0.6, rel.y) * (1.0 - smoothstep(box.y - 1.5, box.y, rel.y));
	float fxz = (1.0 - smoothstep(box.x - 4.0, box.x, abs(rel.x))) * (1.0 - smoothstep(box.z - 4.0, box.z, abs(rel.z)));
	float tw = 0.75 + 0.25 * sin(t * 2.7 + aSeed.w * 21.0);
	vA = aLook.z * fy * fxz * tw * fade;
	float size = aLook.x;
	wp += (INV_VIEW_MATRIX[0].xyz * (UV.x - 0.5) + INV_VIEW_MATRIX[1].xyz * (0.5 - UV.y)) * size;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
	vLook = aLook;
	vColor = CUSTOM3.rgb;
	vRot = aSeed.w * 6.2831 + t * (0.6 + aMotion.w * 1.8);
}
void fragment() {
	vec2 uv = UV - 0.5;
	if (vLook.y > 0.5 && vLook.y < 2.5) {
		float c = cos(vRot);
		float s = sin(vRot);
		uv = mat2(vec2(c, -s), vec2(s, c)) * uv;
	}
	uv += 0.5;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) discard;
	vec2 cell = vec2(mod(vLook.y, 2.0), floor(vLook.y / 2.0));
	vec4 tx = texture(atlas, (uv + cell) * 0.5);
	float a = tx.a * vA;
	if (a < 0.003) discard;
	ALBEDO = vColor * tx.rgb * a;
	ALPHA = a * (1.0 - vLook.w);
}
"""
static var _shader: Shader
static var _atlas: ImageTexture

var profiles: Dictionary = {}
var box := Vector3(28, 9, 24)
var quality_low := false
var reduced_motion := false
var area := ""
var pending := ""
var fade := 0.0
var time := 0.0
var count := 0
var _mi: MeshInstance3D
var _mat: ShaderMaterial

func setup(data: Dictionary) -> void:
	var a: Dictionary = data.atmosphere
	profiles = a.profiles
	box = Vector3(float(a.box.x), float(a.box.y), float(a.box.z))
	name = "Atmosphere"
	_mi = MeshInstance3D.new()
	_mi.name = "Particles"
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_mat.render_priority = 5
	_mat.set_shader_parameter("atlas", atlas_texture())
	_mat.set_shader_parameter("box", box)
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mi.extra_cull_margin = 16384.0
	add_child(_mi)

## Upper bound across profiles (ATMOSPHERE_MAX).
func max_count() -> int:
	var best := 0
	for k in profiles:
		var s := 0
		for kind in profiles[k]:
			s += int(kind.count)
		best = maxi(best, s)
	return best

## Particle counts per profile for `id` (halved on low quality, like the web).
func counts_for(id: String) -> int:
	var s := 0
	for kind in profiles.get(id, []):
		s += int(ceil(float(kind.count) / 2.0)) if quality_low else int(kind.count)
	return s

## Rebuild the particle arrays for an area: the web's Atmosphere.fill, same call order on mulberry32.
func fill(id: String) -> void:
	var rng := DmRng.new(id.length() * 977 + id.unicode_at(0))
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var c2 := PackedFloat32Array()
	var c3 := PackedFloat32Array()
	var n := 0
	for k in profiles.get(id, []):
		var cnt := int(ceil(float(k.count) / 2.0)) if quality_low else int(k.count)
		for i in cnt:
			var sx := rng.next() * box.x * 2.0
			var sy := rng.next() * box.y
			var sz := rng.next() * box.z * 2.0
			var sw := rng.next()
			c0.append_array([sx, sy, sz, sw])
			var mx := (rng.next() - 0.3) * float(k.drift[0])
			var my := _lerp(k.vy, rng)
			var mz := (rng.next() - 0.5) * float(k.drift[1])
			var msway := float(k.sway) * (0.5 + rng.next() * 0.5)
			c1.append_array([mx, my, mz, msway])
			var lsize := _lerp(k.size, rng)
			var lalpha := _lerp(k.alpha, rng)
			c2.append_array([lsize, float(k.shape), lalpha, float(k.add)])
			var colors: Array = k.colors
			var cc := DmWfxData.hex(colors[int(floor(rng.next() * colors.size()))]).srgb_to_linear()
			c3.append_array([cc.r, cc.g, cc.b, 1.0])
			n += 1
	count = n
	_mi.mesh = DmWfxQuads.build(n, c0, c1, c2, c3)
	area = id

static func _lerp(r: Array, rng: DmRng) -> float:
	return float(r[0]) + rng.next() * (float(r[1]) - float(r[0]))

## Cross-fades to the weather of the area the focus stands in ("" = corridor: keep the current one).
func tick(dt: float, area_id: String, focus: Vector3) -> void:
	time += dt
	if area_id != "" and area_id != area and area_id != pending:
		pending = area_id
	if pending != "":
		fade = maxf(0.0, fade - dt * 1.6)
		if fade == 0.0 or area == "":
			fill(pending)
			area = pending
			pending = ""
	else:
		fade = minf(1.0, fade + dt * 0.8)
	var reduced := 0.6 if reduced_motion else 1.0
	_mat.set_shader_parameter("t", time * reduced)
	_mat.set_shader_parameter("fade", fade)
	_mat.set_shader_parameter("focus", focus)

## The web's 128 x 64 atlas: soft dot, ash flake, leaf with midrib, rain streak (drawn on a canvas there; per pixel here).
static func atlas_texture() -> ImageTexture:
	if _atlas != null:
		return _atlas
	var S := 64
	var img := Image.create(S * 2, S * 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	# 0: soft dot, radial gradient 1 -> 0.6 (0.35) -> 0
	for y in S:
		for x in S:
			var d := Vector2(x + 0.5 - S / 2.0, y + 0.5 - S / 2.0).length() / (S / 2.0)
			var a := 0.0
			if d <= 0.35:
				a = 1.0 - 0.4 * (d / 0.35)
			elif d < 1.0:
				a = 0.6 * (1.0 - (d - 0.35) / 0.65)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	# 1: ash flake polygon, 0.9 alpha
	var poly := PackedVector2Array()
	for p in [[0.5, 0.18], [0.74, 0.34], [0.8, 0.6], [0.56, 0.8], [0.3, 0.7], [0.22, 0.42]]:
		poly.append(Vector2(p[0] * S, p[1] * S))
	for y in S:
		for x in S:
			var cov := 0.0
			for sy in 2:
				for sx in 2:
					if Geometry2D.is_point_in_polygon(Vector2(x + 0.25 + sx * 0.5, y + 0.25 + sy * 0.5), poly):
						cov += 0.25
			img.set_pixel(S + x, y, Color(1, 1, 1, 0.9 * cov))
	# 2: leaf with a midrib: x = 0.5 +- 0.84 t (1 - t), y = 0.08 + 0.74 t + 0.1 t^2
	for y in S:
		var yy := (y + 0.5) / S
		var a_ := 0.0
		if yy >= 0.08 and yy <= 0.92:
			# solve 0.1 t^2 + 0.74 t + 0.08 - yy = 0
			var t := (-0.74 + sqrt(0.74 * 0.74 - 0.4 * (0.08 - yy))) / 0.2
			a_ = 0.84 * t * (1.0 - t)
		for x in S:
			var xx := (x + 0.5) / S
			var cov := clampf((a_ - absf(xx - 0.5)) * S + 0.5, 0.0, 1.0) if a_ > 0.0 else 0.0
			var col := Color(1, 1, 1, cov)
			# midrib: 2 px stroke, rgb(120) at 0.9 alpha, y 0.12..0.88
			if yy >= 0.12 and yy <= 0.88 and absf(xx - 0.5) * S < 1.0 and cov > 0.0:
				col = Color(1.0 * 0.1 + 0.47 * 0.9, 1.0 * 0.1 + 0.47 * 0.9, 1.0 * 0.1 + 0.47 * 0.9, 1.0)
			img.set_pixel(x, S + y, col)
	# 3: rain streak, vertical gradient 0 -> 0.9 (0.7) -> 0, 2.4 px wide
	for y in S:
		var g := float(y) / float(S)
		var a3 := 0.9 * (g / 0.7) if g <= 0.7 else 0.9 * (1.0 - (g - 0.7) / 0.3)
		for x in S:
			var left := maxf(x, S / 2.0 - 1.2)
			var right := minf(x + 1, S / 2.0 + 1.2)
			var cov := maxf(0.0, right - left)
			img.set_pixel(S + x, S + y, Color(1, 1, 1, a3 * cov))
	_atlas = ImageTexture.create_from_image(img)
	return _atlas
