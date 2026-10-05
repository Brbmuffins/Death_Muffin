shader_type spatial;
render_mode cull_back;
// Port of the see-through cutout (src/graphics/occlusion.ts) on top of a PBR prop material (albedo + normal + ORM from the glTF import):
// world geometry between the camera and the hero is dithered away inside a screen-space circle around the hero.
global uniform vec4 dm_occ_a;   // x, y = hero NDC; z = radius (NDC); w = camera -> hero distance
global uniform vec4 dm_occ_b;   // x = aspect; y = on (1/0)
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float normal_scale = 1.0;
uniform float roughness_f = 1.0;
uniform float metallic_f = 1.0;
uniform bool has_normal = false;
uniform bool has_orm = false;

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
	vec4 a = texture(albedo_tex, UV) * albedo;
	ALBEDO = a.rgb;
	if (has_orm) {
		vec3 orm = texture(orm_tex, UV).rgb;
		AO = orm.r;
		ROUGHNESS = orm.g * roughness_f;
		METALLIC = orm.b * metallic_f;
	} else {
		ROUGHNESS = roughness_f;
		METALLIC = metallic_f;
	}
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
}
