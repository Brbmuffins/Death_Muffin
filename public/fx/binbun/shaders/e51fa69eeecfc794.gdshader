shader_type spatial;
render_mode unshaded, depth_prepass_alpha;

group_uniforms Noise;
uniform sampler2D noise_texture;
uniform float noise_twist = 3.0;
uniform vec2 scroll_speed = vec2(0.0, 1.0);
uniform float beam_length = 4.0;

group_uniforms Color;
uniform vec3 secondary_color : source_color;
uniform vec3 tertiary_color : source_color;
uniform float emission : hint_range(0.0, 10.0, 0.01) = 3.0;
uniform bool is_tertiary = false;

group_uniforms General;
uniform float open_amount : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float speed_scale : hint_range(0.0, 1.0, 0.01) = 1.0;

group_uniforms Transparency;
uniform float edge_softness : hint_range(0.0, 1.0, 0.01) = 0.5;

float overlay(float base, float blend){
	float limit = step(0.5, base);
	return mix(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), limit);
}

void vertex(){
	float closed_offset = 1.0 - abs(UV.y * 4.0 - 1.0);
	closed_offset = pow(closed_offset, 1.0 - closed_offset);
	closed_offset = UV.y * 4.0;
	closed_offset *= (1.0 - open_amount);

	VERTEX += (NORMAL * closed_offset);
}

void fragment() {
	vec2 uv = UV;
	uv -= vec2(TIME) * scroll_speed * 0.5;

	float noise = texture(noise_texture, uv).r;

	float value = overlay(1.0 - UV.y * 3.0, noise);

	vec3 color = mix(secondary_color, tertiary_color, pow(value, 2.0));

	ALBEDO = vec3(color) * emission;

	float alpha = value;
	alpha = smoothstep(0.7 - (edge_softness * 0.7), 0.7 + (edge_softness * 0.3), alpha);

	float open_mask = UV.y*2.0;
	open_mask = clamp(1.0 - smoothstep(pow(open_amount, 2.0), pow(open_amount, 0.8), open_mask*1.2), 0.0, 1.0);
	alpha *= open_mask;

	ALPHA = alpha;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
