shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

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
//   COLOR.a            hit flash 0..1 (the game's emissive lerp toward the flash colour)
// Per vertex: CUSTOM0.x = the vertex's animation id (a column of the baked textures; UV seams share one id).

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
	v_flash = COLOR.a;
}

void fragment() {
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
	EMISSION = mix(emis, FLASH_COLOR, v_flash) * (emis_k + v_flash * FLASH_EMISSIVE);
}
