shader_type spatial;
render_mode unshaded;

uniform vec3 tertiary_color : source_color;
uniform float emission : hint_range(0.0, 10.0, 0.01) = 3.0;

uniform float dm_gain = 1.0;
void fragment() {
	ALBEDO = tertiary_color * emission * 5.0;

	// dm: gain/fade hooks (tools/godot/fx-binbun-rebuild.ts)
	ALBEDO *= dm_gain;
	EMISSION *= dm_gain;
}
