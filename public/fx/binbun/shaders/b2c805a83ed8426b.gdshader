shader_type spatial;
render_mode blend_mix, depth_prepass_alpha;

group_uniforms Colors;
uniform sampler2D noise_texture;
uniform sampler2D color_gradient;

varying flat int id;
varying vec3 world_pos;

// begin util/dither.gdshaderinc
float bayer4(vec2 frag) {
	int x = int(mod(frag.x, 4.0));
	int y = int(mod(frag.y, 4.0));

	int index = x + y * 4;

	int matrix[16] = int[](
		0,  8,  2, 10,
		12,  4, 14,  6,
		3, 11,  1,  9,
		15,  7, 13,  5
	);

	return float(matrix[index]) / 16.0;
}

float bayer8(vec2 frag) {
	int x = int(mod(frag.x, 8.0));
	int y = int(mod(frag.y, 8.0));

	int index = x + y * 8;

	int matrix[64] = int[](
		0, 32,  8, 40,  2, 34, 10, 42,
		48, 16, 56, 24, 50, 18, 58, 26,
		12, 44,  4, 36, 14, 46,  6, 38,
		60, 28, 52, 20, 62, 30, 54, 22,
		3, 35, 11, 43,  1, 33,  9, 41,
		51, 19, 59, 27, 49, 17, 57, 25,
		15, 47,  7, 39, 13, 45,  5, 37,
		63, 31, 55, 23, 61, 29, 53, 21
	);
	return float(matrix[index]) / 64.0;
}

// end util/dither.gdshaderinc

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float noise_value = texture(noise_texture, world_pos.xz * 0.1).r;
	vec4 color = texture(color_gradient, vec2(noise_value, 0.0));

	ALBEDO = color.rgb;
}

void light(){
	float ndotl = dot(LIGHT, NORMAL) * ATTENUATION;
	DIFFUSE_LIGHT += ndotl;
}
