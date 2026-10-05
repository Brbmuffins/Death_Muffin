shader_type spatial;
// Walls: the world-triplanar stone material of the builder (albedo texture x colour, roughness 0.92) with the see-through cutout.
global uniform vec4 dm_occ_a;
global uniform vec4 dm_occ_b;
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float uv_scale = 0.25;
uniform float roughness_f = 0.92;
varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	if (dm_occ_b.y > 0.5) {
		vec4 clip = PROJECTION_MATRIX * vec4(VERTEX, 1.0);
		vec2 sp = clip.xy / clip.w;
		float r = length((sp - dm_occ_a.xy) * vec2(dm_occ_b.x, 1.0));
		float fd = length(VERTEX);
		if (fd < dm_occ_a.w - 1.2 && r < dm_occ_a.z) {
			vec2 cell = mod(floor(FRAGCOORD.xy), 4.0);
			float bayer = mod(cell.x * 3.0 + cell.y * 7.0, 16.0) / 16.0;
			float edge = smoothstep(dm_occ_a.z, dm_occ_a.z * 0.55, r);
			if (bayer < edge * 0.72) {
				discard;
			}
		}
	}
	vec3 w = pow(abs(wnrm), vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 p = wpos * uv_scale;
	vec4 t = texture(albedo_tex, p.zy) * w.x + texture(albedo_tex, p.xz) * w.y + texture(albedo_tex, p.xy) * w.z;
	ALBEDO = t.rgb * albedo.rgb;
	ROUGHNESS = roughness_f;
}
