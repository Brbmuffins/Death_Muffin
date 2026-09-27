shader_type spatial;
render_mode unshaded;

uniform vec3 tertiary_color : source_color;
uniform float emission : hint_range(0.0, 10.0, 0.01) = 3.0;

void fragment() {
	ALBEDO = tertiary_color * emission * 5.0;
}
