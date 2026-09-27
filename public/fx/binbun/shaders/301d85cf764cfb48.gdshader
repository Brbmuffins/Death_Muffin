shader_type spatial;
render_mode unshaded;

group_uniforms Color;
uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform vec3 tertiary_color : source_color;
uniform float emission : hint_range(0.0, 10.0, 0.01) = 3.0;

group_uniforms Noise;
uniform sampler2D noise_texture;
uniform float noise_twist = 3.0;
uniform vec2 scroll_speed = vec2(0.0, 1.0);
uniform float beam_length = 4.0;

group_uniforms Pulse;
uniform float pulse_speed = 30.0;
uniform float pulse_strength = 0.05;
uniform float pulse_frequency = 30.0;

group_uniforms General;
uniform float open_amount : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float speed_scale : hint_range(0.0, 1.0, 0.01) = 1.0;

group_uniforms Transparency;
uniform float edge_softness : hint_range(0.0, 1.0, 0.01) = 0.5;

void vertex() {
	float closed_offset = 1.0 - abs(UV.y * 4.0 - 1.0);
	closed_offset = pow(closed_offset, 1.0 - closed_offset);
	closed_offset = UV.y * 4.0;
	closed_offset *= (1.0 - open_amount);

	VERTEX += (NORMAL * closed_offset);

	float pulse_base = UV.y;
	float pulse = sin((pulse_base * pulse_frequency) - (TIME*speed_scale) * pulse_speed) * pulse_strength;
	VERTEX += (NORMAL * pulse);
}

void fragment() {
	vec2 uv = UV * vec2(1.0, beam_length);
	uv.x += UV.y * noise_twist;
	uv -= (vec2((TIME*speed_scale)) * scroll_speed);

	float noise = texture(noise_texture, uv).r;
	vec3 color = mix(primary_color, secondary_color, pow(noise, 0.5));

	ALBEDO = color * emission;

	float alpha = noise;
	float open_mask = UV.y*1.0;
	open_mask = clamp(1.0 - smoothstep(open_amount - 0.1, open_amount + 0.1, open_mask), 0.0, 1.0);
	alpha *= open_mask;
	alpha = smoothstep(0.7 - (edge_softness * 0.7), 0.7 + (edge_softness * 0.3), alpha);

	ALPHA = alpha;
}
