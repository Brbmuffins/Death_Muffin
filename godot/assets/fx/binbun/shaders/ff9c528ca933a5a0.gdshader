shader_type spatial;
render_mode unshaded;
stencil_mode write, compare_always, 1;

uniform sampler2D shape_texture;

uniform float open_amount : hint_range(0.0, 1.0, 0.01) = 1.0;

uniform float dm_gain = 1.0;
uniform float dm_fade = 1.0;
void fragment() {
	float shape = texture(shape_texture, UV).r;
	shape = clamp(shape / (open_amount), 0.0, 1.0);

	if(shape > 0.85){
		discard;
	}
	ALPHA = 0.0;

	// dm: gain/fade hooks (tools/godot/fx-binbun-rebuild.ts)
	ALBEDO *= dm_gain;
	EMISSION *= dm_gain;
	ALPHA *= dm_fade;

	// dm: the web port's lit output, unshaded (tools/godot/fx-binbun-hooks.ts unlitHook)
	ALBEDO = ALBEDO * 0.25 + EMISSION;
}
