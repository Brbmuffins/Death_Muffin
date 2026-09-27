shader_type spatial;
render_mode unshaded;

uniform vec3 primary_color : source_color;
uniform vec3 tertiary_color : source_color;
uniform float emission : hint_range(0.0, 10.0, 0.01) = 3.0;

uniform float flash_amount : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float flash_emission : hint_range(0.0, 10.0, 0.01) = 1.0;

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	float gradient = min(UV.y * 2.0, 1.0);

	vec3 color = mix(tertiary_color * emission, primary_color * flash_emission, flash_amount);

	ALBEDO = color;

	ALPHA = COLOR.a;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
