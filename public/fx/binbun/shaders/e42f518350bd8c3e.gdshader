shader_type spatial;
render_mode unshaded, cull_disabled;

group_uniforms Color;
uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform float emission : hint_range(0.0, 10.0, 0.01) = 3.0;

group_uniforms Pulse;
uniform float pulse_speed = 30.0;
uniform float pulse_strength = 0.05;
uniform float pulse_frequency = 30.0;

group_uniforms General;
uniform float open_amount : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float speed_scale : hint_range(0.0, 1.0, 0.01) = 1.0;

void vertex() {
	float closed_offset = 1.0 - abs(UV.y * 4.0 - 1.0);
	closed_offset = pow(closed_offset, 1.0 - closed_offset);
	closed_offset = UV.y * 4.0;
	closed_offset *= (1.0 - open_amount);

	VERTEX += (NORMAL * closed_offset);

	float pulse_base = UV.y;
	float pulse = sin((pulse_base * pulse_frequency) - TIME * pulse_speed) * pulse_strength;
	VERTEX += (NORMAL * pulse);
}

void fragment() {
	float fresnel = clamp(dot(VIEW, NORMAL), 0.0, 1.0);

	vec3 color = mix(primary_color, primary_color * emission, fresnel);

	ALBEDO = color;

	float alpha = 1.0;
	float open_mask = UV.y*2.0;
	open_mask = clamp(1.0 - smoothstep(open_amount - 0.1, open_amount + 0.1, open_mask), 0.0, 1.0);
	alpha *= open_mask;

	ALPHA = alpha;
}
