shader_type spatial;
render_mode blend_mix, unshaded;

uniform sampler2D shape_texture;

uniform vec4 primary_color : source_color;
uniform vec4 secondary_color : source_color;

uniform float dm_gain = 1.0;
void fragment() {
	float mask = texture(shape_texture, UV).r;

	ALBEDO = mix(secondary_color, primary_color, mask).rgb;
	EMISSION = ALBEDO * 4.0;

	if (mask < .1){
		discard;
	}

	// dm: gain/fade hooks (tools/godot/fx-binbun-rebuild.ts)
	ALBEDO *= dm_gain;
	EMISSION *= dm_gain;

	// dm: the web port's lit output, unshaded (tools/godot/fx-binbun-hooks.ts unlitHook)
	ALBEDO = ALBEDO * 0.25 + EMISSION;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
