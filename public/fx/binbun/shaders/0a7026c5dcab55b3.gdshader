shader_type spatial;
render_mode blend_mix;

uniform sampler2D mask_texture;
uniform float mask_exponent = 1.0;
uniform float emission_amount = 2.0;

uniform vec4 primary_color : source_color;
uniform vec4 secondary_color : source_color;

group_uniforms Transparency;
uniform int alpha_mode : hint_range(0, 2, 1) = 0;
uniform float alpha_multiplier : hint_range(0.0, 1.0, 0.01) = 0.765;
uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 4096.0, 0.01) = 1.0;
const vec3 ign = vec3(0.06711056f, 0.00583715f, 52.9829189f);
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
group_uniforms;

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	float mask = texture(mask_texture, UV).r;
	mask = pow(mask, mask_exponent);

	vec3 main_color = mix(secondary_color, primary_color, mask).rgb;

	ALBEDO = main_color;
	EMISSION = ALBEDO * emission_amount;

	float alpha = mask * alpha_multiplier;

	// Proximity Fade: Enabled
	if(proximity_fade){
		float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		vec4 proximity_view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
		proximity_view_pos.xyz /= proximity_view_pos.w;
		alpha *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	}
	if(alpha_mode == 0){
		ALPHA = alpha;
	} else if (alpha_mode == 1) {
		if (alpha < 0.001 || alpha < fract(ign.z * fract(dot(FRAGCOORD.xy, ign.xy)))) {
			discard;
		}
	} else if (alpha_mode == 2) {
		if (alpha < 0.2){
			discard;
		}
	}
}
