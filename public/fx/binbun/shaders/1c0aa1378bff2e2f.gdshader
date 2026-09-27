shader_type spatial;
render_mode blend_mix, cull_disabled;

uniform sampler2D noise_texture;
uniform sampler2D glow_noise_texture;

uniform vec4 primary_color : source_color;

uniform vec2 texture_scale = vec2(1.0);

uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 4096.0, 0.01) = 1.0;

uniform int alpha_mode : hint_range(0, 2, 1) = 0;
const vec3 ign = vec3(0.06711056f, 0.00583715f, 52.9829189f);
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

float noise(vec2 uv) {
	float noise = texture(noise_texture, uv * texture_scale + vec2(TIME * 0.2)).r;
	return noise;
}

void vertex() {
	VERTEX = VERTEX + (NORMAL * noise(UV) * pow(COLOR.a, 0.5) * 0.3) + (NORMAL * pow(COLOR.a, 0.3)*0.1);
}

void fragment() {
	float noise = noise(UV);

	float alpha = 1.0 - smoothstep(noise, 1.0, COLOR.a);
	alpha = smoothstep(0.9, 1.0, alpha);

	ALBEDO = mix(vec3(1.0), primary_color.rgb, COLOR.a);
	ROUGHNESS = 1.0;
	EMISSION = ALBEDO * ((1.0-COLOR.a) * 2.0);

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

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
