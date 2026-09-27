shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled;

uniform sampler2D mask_texture;
uniform sampler2D noise_texture;

uniform float edge_smoothness : hint_range(0.0, 1.0, 0.0) = 0.5;
uniform float color_smoothness : hint_range(0.0, 1.0, 0.1) = 1.0;

uniform vec4 primary_color : source_color;
uniform vec4 secondary_color : source_color;

uniform bool billboard = true;

uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 4096.0, 0.01) = 1.0;

uniform int alpha_mode : hint_range(0, 2, 1) = 0;
const vec3 ign = vec3(0.06711056f, 0.00583715f, 52.9829189f);
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

void vertex() {
	if(billboard){
		// Billboard Mode: Particles
		mat4 mat_world = mat4(
				normalize(INV_VIEW_MATRIX[0]),
				normalize(INV_VIEW_MATRIX[1]),
				normalize(INV_VIEW_MATRIX[2]),
				MODEL_MATRIX[3]);
		mat_world = mat_world * mat4(
				vec4(cos(INSTANCE_CUSTOM.x), -sin(INSTANCE_CUSTOM.x), 0.0, 0.0),
				vec4(sin(INSTANCE_CUSTOM.x), cos(INSTANCE_CUSTOM.x), 0.0, 0.0),
				vec4(0.0, 0.0, 1.0, 0.0),
				vec4(0.0, 0.0, 0.0, 1.0));
		MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;
		// Billboard Keep Scale: Enabled
		MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
				vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
				vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
				vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
				vec4(0.0, 0.0, 0.0, 1.0));
		MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	}
}

void fragment() {
	float mask = texture(mask_texture, UV).r;
	float noise = texture(noise_texture, UV + vec2(COLOR.r)).r;

	float masked_noise = mask - (1.0 - (noise));

	float color_value = smoothstep(0.5 - color_smoothness * 0.5,0.5 + color_smoothness * 0.5,masked_noise);
	float alpha = smoothstep(0.5 - edge_smoothness * 0.5,0.5 + edge_smoothness * 0.5,masked_noise) * COLOR.a;
	//float color_value = smoothstep(0.0,color_smoothness, masked_noise);

	ALBEDO = (mix(secondary_color, primary_color, color_value).rgb + COLOR.rgb) * 2.0;
	EMISSION = ALBEDO;

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
