shader_type spatial;
render_mode blend_mix;

uniform sampler2D noise_texture_1;
uniform sampler2D noise_texture_2;
uniform vec2 mask_from = vec2(0.5);
uniform float mask_scale = 0.4;
uniform float edge_softness = 1.0;

void vertex() {
	mat4 modified_model_view = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
		);
	MODELVIEW_MATRIX = modified_model_view;

	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	float mask = smoothstep((1.0-mask_scale),1.0,1.0-distance(mask_from, UV));

	float warp_noise = texture(noise_texture_2, UV + vec2(0.0, -TIME * 0.2)).r;

	vec2 uv_offset = vec2(COLOR.r * 2.0);
	//vec2 uv_anim =
	float noise = texture(noise_texture_1,(mix(UV*.3, UV*.25, warp_noise)) + uv_offset).r;

	float masked_noise = mask * noise;

	vec3 main_col = mix(vec3(0.4), vec3(0.1), COLOR.a);

	ALBEDO = main_col;


	ALPHA = smoothstep(0.1, edge_softness, masked_noise) * COLOR.a * .4;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
