shader_type spatial;
render_mode blend_mix;

uniform sampler2D shape_texture;

uniform vec4 primary_color : source_color;
uniform vec4 secondary_color : source_color;

void fragment() {
	float mask = texture(shape_texture, UV).r;

	ALBEDO = mix(secondary_color, primary_color, mask).rgb;
	EMISSION = ALBEDO * 4.0;

	if (mask < .1){
		discard;
	}
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
