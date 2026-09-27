shader_type spatial;
render_mode blend_mix, cull_disabled;

group_uniforms Texture;
uniform sampler2D main_texture;
uniform vec2 texture_scale = vec2(1.0);
uniform int alignment : hint_range(0, 3, 1);

group_uniforms Noise;
uniform sampler2D noise_texture;
uniform vec2 noise_scrolling = vec2(0.0);
uniform float noise_strength : hint_range(0.0, 1.0, 0.1) = 0.5;

group_uniforms Colors;
uniform vec4 primary_color : source_color;
uniform vec4 secondary_color : source_color;
uniform vec4 tertiary_color : source_color;

group_uniforms Offset;
uniform sampler2D offset_texture;
uniform float offset_distance = 0.0;
uniform float offset_exponent = 1.0;

group_uniforms Emission;
uniform float emission_strength : hint_range(0.0, 10.0, 0.1) = 2.0;

group_uniforms Smoothness;
uniform float color_smoothness : hint_range(0.0, 1.0, 0.1) = 1.0;
uniform float edge_smoothness : hint_range(0.0, 1.0, 0.1) = 1.0;

group_uniforms Animation;
uniform float fade_basic_amount : hint_range(0.0, 1.0, 0.05) = 0.121;
uniform float fade_direction_amount : hint_range(0.0, 1.0, 0.05) = 0.121;
uniform bool use_particle_alpha = false;

group_uniforms Transparency;
uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 4096.0, 0.01) = 1.0;
uniform float edge_cutoff_distance : hint_range(0.0, 0.5, 0.01) = 0.0534;
uniform int alpha_mode : hint_range(0, 2, 1) = 0;
const vec3 ign = vec3(0.06711056f, 0.00583715f, 52.9829189f);
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

group_uniforms;

void vertex(){
	float offset = texture(offset_texture, UV).r;
	float edge_distance = pow(offset, offset_exponent) * offset_distance;
	VERTEX += NORMAL * edge_distance;
}

vec2 align(vec2 uv) {
	switch(alignment){
		case 0: return vec2(uv.x, uv.y);
		case 1: return vec2(uv.y, uv.x);
		case 2: return vec2(1.0 - uv.x, uv.y);
		case 3: return vec2(1.0 - uv.y, uv.x);
	}
	return vec2(uv.x, uv.y);
}

float fade_direction(float value, float amount, vec2 uv){
	float uv_value = (uv.y-1.0) + (amount * 1.3);
	uv_value = clamp(uv_value, 0.0, 1.0);

	float faded_value = value - uv_value;
	faded_value = clamp(faded_value, 0.0, 1.0);
	return faded_value;
}

float noise(sampler2D tex, vec2 uv, float time) {
	vec2 scrolled_uv = uv + (vec2(TIME) * noise_scrolling);

	float value = texture(tex, scrolled_uv).r;
	return value;
}

void fragment() {
	float main_value = texture(main_texture, align(UV * texture_scale)).r;

	main_value = fade_direction(main_value, COLOR.a *  fade_direction_amount, UV);
	main_value = mix(main_value, main_value * (1.0 - COLOR.a), fade_basic_amount);
	main_value *= 1.0 - ((1.0 - noise(noise_texture, UV, TIME)) * noise_strength);

	// Handle Transparency
	float alpha = smoothstep(0.0, edge_smoothness, main_value);
	alpha *= step(edge_cutoff_distance, min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y)));

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

	float color_value = smoothstep(0.0, color_smoothness, main_value);
	vec3 main_color = mix(secondary_color, primary_color, color_value).rgb;

	ALBEDO = main_color;
	EMISSION = ALBEDO * emission_strength;
}
