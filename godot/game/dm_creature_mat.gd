class_name DmCreatureMat
extends RefCounted
## The creature material: one spatial shader (built from fragments, cached per variant) standing in for the web's patched
## MeshStandardMaterial (Creature.ts style(), creatureMaterials.ts, friendRim.ts, gearTint.ts, wingFlap.ts):
##  - tint (colour multiplier) + emissive colour/intensity (the hit flash drives the emissive, as applyFlash does)
##  - friendly fresnel rim (friendRim.ts, the exact formula: emissive += rim.rgb * strength * smoothstep(.35,.95,fres) * .9)
##  - gear regions (gearTint.ts): chest/legs/hands/feet masks baked per mesh from the skin weights into COLOR, head into UV2
##  - vertex wing flap (wingFlap.ts) for moth / bat / seraph
##  - fade variant (blend_mix, no depth write) for opacity < 1 and spectral bodies
## Source textures come from the imported glTF StandardMaterial3D (albedo, ORM, normal).

static var _shaders: Dictionary = {}
static var _baked: Dictionary = {}   # source ArrayMesh -> gear-masked ArrayMesh
static var _region_re: Array = []

## Models whose glTF surface is a closed body (under 2% open edges, triangle winding agrees with the normals; measured offline per mesh): they render
## back-face culled. Every other model keeps cull_disabled: hair cards, cloaks, open robes, wings and thin cloth show their inside from behind
## (hero_ossuary / hero_mourner / bog_hag / pyre_priest / wraith_thrall are 15-24% open edges). Winged and spectral bodies are never in the cull path.
const CULL_BACK_SLUGS := ["necromancer", "hero_gravecaller", "hero_rotweaver", "hero_grave_warden", "hero_carrion_witch", "hero_veilwalker",
	"carrion_sac", "boss_gravedigger_king", "boss_drowned_congregation", "boss_cinder_regent", "thrall_sentinel", "skull_rat", "bone_golem",
	"bone_colossus", "belfry_gargoyle", "bell_templar", "cinderhound", "slag_brute", "mire_leech", "fen_wisp", "skull_niche",
	"npc_prior", "npc_sexton", "npc_apothecary"]

const REGION_OF_BONE := [["Foot|ToeBase", 3], ["Hand|Forearm", 2], ["Thigh|Calf|Pelvis|^Hip$", 1], ["Spine|Waist|Clavicle|Upperarm", 0]]

static func shader(fade: bool, wings: bool, gear: bool, cull_back := false) -> Shader:
	var key := "%d%d%d%d" % [int(fade), int(wings), int(gear), int(cull_back)]
	if _shaders.has(key):
		return _shaders[key]
	var c := "shader_type spatial;\n"
	c += "render_mode blend_mix, %s, %s, diffuse_burley, specular_schlick_ggx;\n" % [("depth_draw_never" if fade else "depth_draw_opaque"), ("cull_back" if cull_back else "cull_disabled")]
	c += """
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_col : source_color = vec4(1.0);
uniform float rough_f = 1.0;
uniform float metal_f = 1.0;
uniform bool use_orm = false;
uniform bool use_normal = false;
uniform vec3 tint = vec3(1.0);
uniform vec3 emis = vec3(0.0);
uniform float emis_k = 0.0;
uniform float opacity = 1.0;
uniform vec4 rim = vec4(0.0);
"""
	if gear:
		c += """
uniform vec4 gt0 = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec4 gt1 = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec4 gt2 = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec4 gt3 = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec3 gg0 = vec3(0.0);
uniform vec3 gg1 = vec3(0.0);
uniform vec3 gg2 = vec3(0.0);
uniform vec3 gg3 = vec3(0.0);
uniform vec4 head_t = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec3 head_g = vec3(0.0);
"""
	if wings:
		c += """
uniform vec4 wing = vec4(0.0);      // speed, amp, body, half
uniform vec2 wing_root = vec2(0.0); // centre, phase
uniform float wing_z = 0.0;
void vertex() {
	float ws = (wing_z > 0.5 ? VERTEX.z : VERTEX.x) - wing_root.x;
	float wd = abs(ws) - wing.z;
	if (wd > 0.0) {
		float wf = smoothstep(0.0, max(0.001, wing.w - wing.z), wd);
		float wa = wing.y * sin(TIME * wing.x + wing_root.y) * (0.35 + 0.65 * wf);
		float nv = wing_root.x + sign(ws) * (wing.z + wd * cos(wa));
		if (wing_z > 0.5) { VERTEX.z = nv; } else { VERTEX.x = nv; }
		VERTEX.y += wd * sin(wa);
	}
}
"""
	c += """
void fragment() {
	vec4 a = texture(albedo_tex, UV) * albedo_col;
	vec3 alb = a.rgb * tint;
	vec3 glow = vec3(0.0);
"""
	if gear:
		c += """
	float lum = dot(alb, vec3(0.299, 0.587, 0.114));
	vec4 gm = COLOR;
	float m0 = clamp(gm.r * gt0.w, 0.0, 1.0);
	float m1 = clamp(gm.g * gt1.w, 0.0, 1.0);
	float m2 = clamp(gm.b * gt2.w, 0.0, 1.0);
	float m3 = clamp(gm.a * gt3.w, 0.0, 1.0);
	alb = mix(alb, gt0.rgb * (0.22 + lum * 1.5), m0);
	alb = mix(alb, gt1.rgb * (0.22 + lum * 1.5), m1);
	alb = mix(alb, gt2.rgb * (0.22 + lum * 1.5), m2);
	alb = mix(alb, gt3.rgb * (0.22 + lum * 1.5), m3);
	float mh = clamp(UV2.x * head_t.w, 0.0, 1.0);
	alb = mix(alb, head_t.rgb * (0.22 + lum * 1.5), mh);
	glow = gg0 * gm.r * gt0.w + gg1 * gm.g * gt1.w + gg2 * gm.b * gt2.w + gg3 * gm.a * gt3.w + head_g * UV2.x * head_t.w;
"""
	c += """
	ALBEDO = alb;
	if (use_orm) {
		vec3 orm = texture(orm_tex, UV).rgb;
		ROUGHNESS = clamp(orm.g * rough_f, 0.04, 1.0);
		METALLIC = clamp(orm.b * metal_f, 0.0, 1.0);
	} else {
		ROUGHNESS = rough_f;
		METALLIC = 0.0;
	}
	if (use_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
	float fres = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	vec3 rimc = rim.rgb * rim.a * smoothstep(0.35, 0.95, fres) * 0.9;
	EMISSION = emis * emis_k + rimc + glow;
"""
	if fade:
		c += "	ALPHA = opacity * a.a;\n"
	c += "}\n"
	var sh := Shader.new()
	sh.code = c
	_shaders[key] = sh
	return sh

## A ShaderMaterial carrying `src`'s textures and factors. `flags`: fade / wings / gear / cull_back (closed bodies only, CULL_BACK_SLUGS).
static func make(src: Material, fade: bool, wings: bool, gear: bool, cull_back := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader(fade, wings, gear, cull_back)
	if src is BaseMaterial3D:
		var b := src as BaseMaterial3D
		if b.albedo_texture != null:
			m.set_shader_parameter("albedo_tex", b.albedo_texture)
		m.set_shader_parameter("albedo_col", b.albedo_color)
		var orm: Texture2D = b.roughness_texture if b.roughness_texture != null else b.metallic_texture
		if orm != null:
			m.set_shader_parameter("orm_tex", orm)
			m.set_shader_parameter("use_orm", true)
		m.set_shader_parameter("rough_f", b.roughness)
		m.set_shader_parameter("metal_f", b.metallic)
		if b.normal_enabled and b.normal_texture != null:
			m.set_shader_parameter("normal_tex", b.normal_texture)
			m.set_shader_parameter("use_normal", true)
	return m

static func _regions() -> Array:
	if _region_re.is_empty():
		for r in REGION_OF_BONE:
			var re := RegEx.new()
			re.compile(r[0])
			_region_re.append([re, r[1]])
	return _region_re

## Gear-region masks (gearTint.ts bakeMask): a copy of the mesh whose COLOR holds the chest/legs/hands/feet skin weights and UV2.x the
## Head weight. Cached per source mesh (every instance of a model shares it).
static func baked_mesh(mi: MeshInstance3D) -> Mesh:
	var src := mi.mesh as ArrayMesh
	if src == null or mi.skin == null:
		return mi.mesh
	if _baked.has(src):
		return _baked[src]
	var skin := mi.skin
	var region: PackedInt32Array = PackedInt32Array()
	var head_bind := -1
	for i in skin.get_bind_count():
		var nm := String(skin.get_bind_name(i))
		var r := -1
		for rr in _regions():
			if (rr[0] as RegEx).search(nm) != null:
				r = rr[1]
				break
		region.append(r)
		if nm == "Head":
			head_bind = i
	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var n := verts.size()
		var per := (bones.size() / n) if n > 0 else 4
		var col := PackedColorArray()
		var uv2 := PackedVector2Array()
		col.resize(n)
		uv2.resize(n)
		for v in n:
			var c := [0.0, 0.0, 0.0, 0.0]
			var h := 0.0
			for k in per:
				var bi := bones[v * per + k]
				var w := weights[v * per + k]
				if bi >= 0 and bi < region.size():
					var r := region[bi]
					if r >= 0:
						c[r] += w
					if bi == head_bind:
						h += w
			col[v] = Color(c[0], c[1], c[2], c[3])
			uv2[v] = Vector2(h, 0.0)
		arrays[Mesh.ARRAY_COLOR] = col
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		var flags := 0
		if per == 8:
			flags |= Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		out.add_surface_from_arrays(src.surface_get_primitive_type(s), arrays, [], {}, flags)
		out.surface_set_material(s, src.surface_get_material(s))
	_baked[src] = out
	return out
