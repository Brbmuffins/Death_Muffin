shader_type spatial;
render_mode blend_mix, unshaded;

uniform sampler2D mask_texture;
uniform sampler2D noise_texture;

uniform float edge_smoothness : hint_range(0.0, 1.0, 0.0) = 0.5;
uniform float color_smoothness : hint_range(0.0, 1.0, 0.1) = 1.0;

uniform vec4 tertiary_color : source_color;
uniform float alpha_multiplier : hint_range(0.0, 1.0, 0.1) = 1.0;

uniform int alpha_mode : hint_range(0, 2, 1) = 0;
const vec3 ign = vec3(0.06711056f, 0.00583715f, 52.9829189f);
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

void vertex() {
    mat4 modified_model_view = VIEW_MATRIX * mat4(
        INV_VIEW_MATRIX[0],
        INV_VIEW_MATRIX[1],
        INV_VIEW_MATRIX[2],
        MODEL_MATRIX[3]
    );
    MODELVIEW_MATRIX = modified_model_view;
}

void fragment() {
	float mask = texture(mask_texture, UV).r;
	float noise = texture(noise_texture, UV + vec2(COLOR.r)).r;

	float masked_noise = mask - (1.0 - (noise - pow(COLOR.a, 4.0)));

	float alpha = smoothstep(0.5 - edge_smoothness * 0.5,0.5 + edge_smoothness * 0.5,masked_noise) * alpha_multiplier;
	//float color_value = smoothstep(0.0,color_smoothness, masked_noise);

	ALBEDO = tertiary_color.rgb;
	//EMISSION = ALBEDO * 2.0;

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
