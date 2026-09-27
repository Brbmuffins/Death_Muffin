shader_type spatial;
render_mode blend_mix;

uniform sampler2D noise_texture_1;
uniform sampler2D noise_texture_2;
uniform sampler2D texture_mask;
uniform float edge_softness = 1.0;
uniform vec2 texture_scale = vec2(1.0,1.0);

uniform vec4 smoke_color : source_color;
uniform float lightness = 0.0;

uniform vec2 mask_from = vec2(0.5);
uniform float mask_scale = 0.4;

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
	float lifetime = 0.5 + COLOR.a * 0.5;

	float warp_noise = 1.0-(texture(noise_texture_2,(UV + vec2(-TIME * 0.5, 0.0))).r * .0003);

	vec2 uv_offset = vec2(COLOR.r * 2.0);
	uv_offset = uv_offset + (vec2(sin(TIME*1.0)*.1,COLOR.a*.1)*warp_noise);
	float noise = texture(noise_texture_1,(UV*.3*texture_scale) + uv_offset).r;

	float mask = smoothstep(1.0-mask_scale,1.0,1.0-distance(mask_from, UV));

	float masked_noise = mask * noise;

	vec3 main_color = vec3(1.0, lightness+(pow(COLOR.a, 8.0)*.1), (pow(COLOR.a, 16.0)*lightness));
	main_color = mix(smoke_color.rgb, main_color, pow(COLOR.a, 8.0));

	ALBEDO = main_color;
	EMISSION = ALBEDO * 3.0 * pow(COLOR.a, 16.0);

	ALPHA = smoothstep(0.3, edge_softness, masked_noise) * pow(COLOR.a, 2.0);
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
