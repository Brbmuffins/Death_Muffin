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
//   COLOR.a            palette slot * 2 + hit flash 0..1: the slot picks the body's glow from `glow_palette` (0 = this model's own `emis`, `emis_k`) and its friend rim
//                      from `rim_palette` (a thrall's: DmCreatureMat's `rim`), the flash is the game's emissive lerp toward the flash colour (in eighths, so exact in a
//                      half float up to slot 127)
// Per vertex: CUSTOM0.y = its material part: 0 the body, k a hand prop's part k (a thrall variant's sword, shield, bow or staff: `part_*`, no tint, flash or
// glow, as today's props). A body vertex's CUSTOM0.x = its animation id (a column of the baked textures; UV seams share one id); a prop vertex sits in its
// prop's own space (VERTEX, NORMAL) and its CUSTOM0.x = which prop of the variant: the prop's transform comes from the baked track of the hand.

// The model's own textures and factors, as DmCreatureMat takes them from the glTF material (the glTF's own defaults: both factors 1, the ORM texture scales them).
// The crowd mesh has no tangents: the normal map gets its frame from the screen-space derivatives of the position and the UVs (`bumped`).
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_col : source_color = vec4(1.0);
uniform float rough_f = 1.0;
uniform float metal_f = 1.0;
uniform bool use_orm = false;
uniform bool use_normal = false;
// Body emissive (linear), like DmCreature's emis / emis_k; the hit flash lerps it toward FLASH_COLOR.
uniform vec3 emis = vec3(0.0);
uniform float emis_k = 0.0;
// Per-body glows (DmCrowd.glow_palette: linear rgb + strength): the elite's, the risen's, a legion's thralls'... Slot 0 is unused (the model's own above).
uniform vec4 glow_palette[128];
// Per-body friend rims (DmCrowd.rim_palette: linear rgb + strength), the same slots: a thrall's spirit rim, weaker on another player's, a champion's gold. DmCreatureMat's
// `emissive += rim.rgb * strength * smoothstep(.35, .95, fresnel) * .9`. Slot 0 and every enemy: none.
uniform vec4 rim_palette[128];
// Hand props' parts (CrowdVatData.part_*): linear albedo, (metallic, roughness, -, -), linear emission.
uniform vec4 part_albedo[8];
uniform vec4 part_pbr[8];
uniform vec4 part_emission[8];

// Baked animation: positions (RGBA8, xyz in the creature's space as three integer codes in 32 bits, below) and normals (RG8, octahedral), one frame =
// rows_per_frame rows.
uniform sampler2D vat_pos : filter_nearest, repeat_disable;
uniform sampler2D vat_nrm : filter_nearest, repeat_disable;
uniform int vat_width = 1;
uniform int vat_rows = 1;
// The codes of a position n (the four bytes, low first): x = n mod vat_rx, y = (n / vat_rx) mod vat_ry, z = n / (vat_rx * vat_ry); position = vat_lo + code * vat_step.
// vat_rx is a power of two and vat_hi = 65536 / vat_rx: the integers stay within 32 bits signed.
uniform vec3 vat_lo = vec3(0.0);
uniform vec3 vat_step = vec3(1.0);
uniform int vat_rx = 2048;
uniform int vat_ry = 2048;
uniform int vat_hi = 32;
// Clip table: x first frame, y frame count, z frames per second, w 1 = loop / 0 = hold the last frame.
uniform vec4 vat_clips[16];
// Hand props (a thrall variant): the hand's transform for every frame, three RGBAF texels a prop (the rows of a 3x4 matrix, translation in w), one row a frame.
// Its clip table (a track may be sampled finer than the body).
uniform sampler2D vat_track : filter_nearest, repeat_disable;
uniform vec4 trk_clips[16];

const vec3 FLASH_COLOR = vec3(1.0, 0.87137, 0.71569); // 0xfff0dc in linear, DmCreature.FLASH_COLOR
const float FLASH_EMISSIVE = 0.16;                    // DmCreature._apply_flash: emis_k + f * 0.16

varying float v_flash;
varying flat vec4 v_glow;
varying flat vec3 v_rim;   // the rim's colour x strength x 0.9
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

// The two frames around `time` of a clip row `c` and how far toward the second.
void vat_frames(vec4 c, float time, out int i0, out int i1, out float k) {
	int count = int(c.y + 0.5);
	float f = max(time, 0.0) * c.z;
	if (c.w > 0.5) {
		f = mod(f, float(count));
		i0 = min(int(floor(f)), count - 1);
		i1 = (i0 + 1 >= count) ? 0 : i0 + 1;
	} else {
		f = clamp(f, 0.0, float(count - 1));
		i0 = int(floor(f));
		i1 = min(i0 + 1, count - 1);
	}
	k = f - float(i0);
}

vec3 vat_decode_pos(vec4 t) {
	ivec4 b = ivec4(t * 255.0 + 0.5);
	int lo = b.r + b.g * 256;
	int hi = b.b + b.a * 256;
	int w = lo / vat_rx + hi * vat_hi;
	return vat_lo + vec3(float(lo % vat_rx), float(w % vat_ry), float(w / vat_ry)) * vat_step;
}

void vat_pose(int clip, float time, int id, out vec3 p, out vec3 n) {
	vec4 c = vat_clips[clip];
	int i0;
	int i1;
	float k;
	vat_frames(c, time, i0, i1, k);
	int base = int(c.x + 0.5);
	ivec2 a = vat_texel(base + i0, id);
	ivec2 b = vat_texel(base + i1, id);
	p = mix(vat_decode_pos(texelFetch(vat_pos, a, 0)), vat_decode_pos(texelFetch(vat_pos, b, 0)), k);
	n = mix(vat_decode_normal(texelFetch(vat_nrm, a, 0).xy), vat_decode_normal(texelFetch(vat_nrm, b, 0).xy), k);
}

// The transform of hand prop `slot` at `time` of a clip: the three rows, interpolated between the frames as the body's positions are.
void trk_pose(int clip, float time, int slot, out vec4 r0, out vec4 r1, out vec4 r2) {
	vec4 c = trk_clips[clip];
	int i0;
	int i1;
	float k;
	vat_frames(c, time, i0, i1, k);
	int base = int(c.x + 0.5);
	ivec2 a = ivec2(slot * 3, base + i0);
	ivec2 b = ivec2(slot * 3, base + i1);
	r0 = mix(texelFetch(vat_track, a, 0), texelFetch(vat_track, b, 0), k);
	r1 = mix(texelFetch(vat_track, a + ivec2(1, 0), 0), texelFetch(vat_track, b + ivec2(1, 0), 0), k);
	r2 = mix(texelFetch(vat_track, a + ivec2(2, 0), 0), texelFetch(vat_track, b + ivec2(2, 0), 0), k);
}

void vertex() {
	vec4 d = INSTANCE_CUSTOM;
	int clip = clamp(int(d.x + 0.5), 0, 15);
	float prev = floor(d.z);
	float weight = d.z - prev;
	int prev_clip = clamp(int(prev), 0, 15);
	vec3 p;
	vec3 n;
	if (CUSTOM0.y > 0.5) {   // a hand prop: its rigid mesh through the hand's transform (the same blend as the body's positions)
		int slot = int(CUSTOM0.x + 0.5);
		vec4 r0;
		vec4 r1;
		vec4 r2;
		trk_pose(clip, d.y, slot, r0, r1, r2);
		if (weight > 0.0) {
			vec4 s0;
			vec4 s1;
			vec4 s2;
			trk_pose(prev_clip, d.w, slot, s0, s1, s2);
			r0 = mix(r0, s0, weight);
			r1 = mix(r1, s1, weight);
			r2 = mix(r2, s2, weight);
		}
		p = vec3(dot(r0.xyz, VERTEX) + r0.w, dot(r1.xyz, VERTEX) + r1.w, dot(r2.xyz, VERTEX) + r2.w);
		n = vec3(dot(r0.xyz, NORMAL), dot(r1.xyz, NORMAL), dot(r2.xyz, NORMAL));
	} else {
		vat_pose(clip, d.y, int(CUSTOM0.x + 0.5), p, n);
		if (weight > 0.0) {
			vec3 p2;
			vec3 n2;
			vat_pose(prev_clip, d.w, int(CUSTOM0.x + 0.5), p2, n2);
			p = mix(p, p2, weight);
			n = mix(n, n2, weight);
		}
	}
	VERTEX = p;
	NORMAL = normalize(n);
	float slot_glow = floor(COLOR.a * 0.5 + 0.001);
	v_flash = clamp(COLOR.a - slot_glow * 2.0, 0.0, 1.0);
	int slot = clamp(int(slot_glow), 1, 127);
	v_glow = slot_glow > 0.5 ? glow_palette[slot] : vec4(emis, emis_k);
	v_rim = slot_glow > 0.5 ? rim_palette[slot].rgb * (rim_palette[slot].a * 0.9) : vec3(0.0);
	v_part = CUSTOM0.y;
}

// The normal map's frame from the screen-space derivatives (no tangent attribute): `map` is the sampled texel, `n` the view-space normal. Godot's own frame points its
// tangent along +U and its bitangent along -V (the glTF convention: OpenGL normal maps with V down), and reconstructs z from xy as it does for NORMAL_MAP.
vec3 bumped(vec3 n, vec3 pos, vec2 uv, vec3 map) {
	vec3 m = vec3(map.xy * 2.0 - 1.0, 0.0);
	m.z = sqrt(max(0.0, 1.0 - dot(m.xy, m.xy)));
	vec3 dp1 = dFdx(pos);
	vec3 dp2 = dFdy(pos);
	vec2 du1 = dFdx(uv);
	vec2 du2 = dFdy(uv);
	vec3 p2 = cross(dp2, n);
	vec3 p1 = cross(n, dp1);
	vec3 t = p2 * du1.x + p1 * du2.x;
	vec3 b = -(p2 * du1.y + p1 * du2.y);
	float inv = inversesqrt(max(max(dot(t, t), dot(b, b)), 1e-20));
	return normalize(t * (inv * m.x) + b * (inv * m.y) + n * m.z);
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
		vec3 n = normalize(NORMAL);
		float fres = 1.0 - clamp(dot(n, normalize(VIEW)), 0.0, 1.0);   // from the geometric normal, as DmCreatureMat's rim reads NORMAL before the normal map
		EMISSION = mix(v_glow.rgb, FLASH_COLOR, v_flash) * (v_glow.a + v_flash * FLASH_EMISSIVE) + v_rim * smoothstep(0.35, 0.95, fres);
		if (use_normal) {
			NORMAL = bumped(n, VERTEX, UV, texture(normal_tex, UV).rgb);
		}
	}
#ifdef SPECTRAL
	ALPHA = SPECTRAL_OPACITY;
#endif
}
