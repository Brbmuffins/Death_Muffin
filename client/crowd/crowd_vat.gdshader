shader_type spatial;
#ifdef SPECTRAL
// A spectral body (CrowdVatData.spectral_shader: this code with SPECTRAL defined): DmCreature's fade variant, see-through at SPECTRAL_OPACITY, writing no depth.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, blend_mix, depth_draw_never;
const float SPECTRAL_OPACITY = 0.55;  // DmCreature: opacity 0.55 for a spectral body
#else
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;
#endif

// The crowd material: plays a baked vertex animation (client/crowd/README.md) for every instance of a MultiMesh.
// One material per creature model. Runs on Forward+, Mobile and Compatibility: vertex texture fetch, integer maths and
// per-instance data only (no screen or depth textures, no Forward+-only built-ins).
//
// Per instance (MultiMesh with use_colors and use_custom_data):
//   INSTANCE_CUSTOM.x  clip index (the model's clip table)
//   INSTANCE_CUSTOM.y  seconds into that clip (the clip's own time; a loop wraps, a one-shot holds its last frame)
//   INSTANCE_CUSTOM.z  previous clip index + blend weight 0..<1 of the previous pose (0 = no blend, then w is ignored)
//   INSTANCE_CUSTOM.w  seconds into the previous clip
//   COLOR.rgb          linear tint multiplier (white = the texture as is)
//   COLOR.a            glow slot * 2 + hit flash 0..1: the slot picks the body's glow from `glow_palette` (0 = this model's own `emis`, `emis_k`), the
//                      flash is the game's emissive lerp toward the flash colour (in eighths, so exact in a half float up to slot 63)
// Per vertex: CUSTOM0.x = the vertex's animation id (a column of the baked textures; UV seams share one id), CUSTOM0.y = its material part: 0 the
// body (the textures above), k a hand prop's part k (a thrall variant's sword, shield, bow or staff: `part_*`, no tint, flash or glow, as today's props).

// The model's own textures, as DmCreatureMat takes them from the glTF material (no normal map: the crowd mesh has no tangents).
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_col : source_color = vec4(1.0);
uniform float rough_f = 1.0;
uniform float metal_f = 0.0;
uniform bool use_orm = false;
// Body emissive (linear), like DmCreature's emis / emis_k; the hit flash lerps it toward FLASH_COLOR.
uniform vec3 emis = vec3(0.0);
uniform float emis_k = 0.0;
// Per-body glows (DmCrowd.glow_palette: linear rgb + strength): the elite's, the risen's, a legion's thralls'... Slot 0 is unused (the model's own above).
uniform vec4 glow_palette[64];
// Hand props' parts (CrowdVatData.part_*): linear albedo, (metallic, roughness, -, -), linear emission.
uniform vec4 part_albedo[8];
uniform vec4 part_pbr[8];
uniform vec4 part_emission[8];

// Baked animation: positions (RGBAH, xyz in the creature's space) and normals (RG8, octahedral), one frame = rows_per_frame rows.
uniform sampler2D vat_pos : filter_nearest, repeat_disable;
uniform sampler2D vat_nrm : filter_nearest, repeat_disable;
uniform int vat_width = 1;
uniform int vat_rows = 1;
// Clip table: x first frame, y frame count, z frames per second, w 1 = loop / 0 = hold the last frame.
uniform vec4 vat_clips[16];

const vec3 FLASH_COLOR = vec3(1.0, 0.87137, 0.71569); // 0xfff0dc in linear, DmCreature.FLASH_COLOR
const float FLASH_EMISSIVE = 0.16;                    // DmCreature._apply_flash: emis_k + f * 0.16

varying float v_flash;
varying flat vec4 v_glow;
varying flat float v_part;

ivec2 vat_texel(int frame, int id) {
	int r = id / vat_width;
	return ivec2(id - r * vat_width, frame * vat_rows + r);
}

vec3 vat_decode_normal(vec2 e) {
	e = e * 2.0 - 1.0;
	vec3 n = vec3(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
	float t = max(-n.z, 0.0);
	n.x += (n.x >= 0.0) ? -t : t;
	n.y += (n.y >= 0.0) ? -t : t;
	return normalize(n);
}

void vat_pose(int clip, float time, int id, out vec3 p, out vec3 n) {
	vec4 c = vat_clips[clip];
	int count = int(c.y + 0.5);
	float f = max(time, 0.0) * c.z;
	int i0;
	int i1;
	if (c.w > 0.5) {
		f = mod(f, float(count));
		i0 = min(int(floor(f)), count - 1);
		i1 = (i0 + 1 >= count) ? 0 : i0 + 1;
	} else {
		f = clamp(f, 0.0, float(count - 1));
		i0 = int(floor(f));
		i1 = min(i0 + 1, count - 1);
	}
	float k = f - float(i0);
	int base = int(c.x + 0.5);
	ivec2 a = vat_texel(base + i0, id);
	ivec2 b = vat_texel(base + i1, id);
	p = mix(texelFetch(vat_pos, a, 0).xyz, texelFetch(vat_pos, b, 0).xyz, k);
	n = mix(vat_decode_normal(texelFetch(vat_nrm, a, 0).xy), vat_decode_normal(texelFetch(vat_nrm, b, 0).xy), k);
}

void vertex() {
	int id = int(CUSTOM0.x + 0.5);
	vec4 d = INSTANCE_CUSTOM;
	vec3 p;
	vec3 n;
	vat_pose(clamp(int(d.x + 0.5), 0, 15), d.y, id, p, n);
	float prev = floor(d.z);
	float weight = d.z - prev;
	if (weight > 0.0) {
		vec3 p2;
		vec3 n2;
		vat_pose(clamp(int(prev), 0, 15), d.w, id, p2, n2);
		p = mix(p, p2, weight);
		n = mix(n, n2, weight);
	}
	VERTEX = p;
	NORMAL = normalize(n);
	float slot = floor(COLOR.a * 0.5 + 0.001);
	v_flash = clamp(COLOR.a - slot * 2.0, 0.0, 1.0);
	v_glow = slot > 0.5 ? glow_palette[clamp(int(slot), 1, 63)] : vec4(emis, emis_k);
	v_part = CUSTOM0.y;
}

void fragment() {
	if (v_part > 0.5) {   // a hand prop: its own flat material
		int k = clamp(int(v_part + 0.5) - 1, 0, 7);
		ALBEDO = part_albedo[k].rgb;
		METALLIC = part_pbr[k].x;
		ROUGHNESS = part_pbr[k].y;
		EMISSION = part_emission[k].rgb;
	} else {
		vec4 a = texture(albedo_tex, UV) * albedo_col;
		ALBEDO = a.rgb * COLOR.rgb;
		if (use_orm) {
			vec3 orm = texture(orm_tex, UV).rgb;
			ROUGHNESS = clamp(orm.g * rough_f, 0.04, 1.0);
			METALLIC = clamp(orm.b * metal_f, 0.0, 1.0);
		} else {
			ROUGHNESS = rough_f;
			METALLIC = 0.0;
		}
		EMISSION = mix(v_glow.rgb, FLASH_COLOR, v_flash) * (v_glow.a + v_flash * FLASH_EMISSIVE);
	}
#ifdef SPECTRAL
	ALPHA = SPECTRAL_OPACITY;
#endif
}
