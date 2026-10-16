shader_type spatial;
render_mode unshaded, blend_mix;

uniform vec3 primary_color : source_color;
uniform sampler2D particle_texture;
uniform bool use_texture = false;
uniform bool lock = false;
uniform float emission = 2.0;

void vertex(){
	VERTEX.y += sin(TIME * 2.0 + float(INSTANCE_ID)) * 0.05;
}

uniform float dm_gain = 1.0;
uniform float dm_fade = 1.0;
void fragment() {
	float shape = 0.0;

	if(use_texture && !lock){
		shape = texture(particle_texture, UV).a;
		ALPHA = shape * COLOR.a;
	} else {
		vec2 tile_uv = fract(UV - 0.5);

		shape = length(tile_uv * 2.0 - 1.0);
		shape = smoothstep(1.0, 1.2, shape);
		ALPHA = shape * COLOR.a;
	}


	ALBEDO = primary_color * emission;

	// dm: gain/fade hooks (tools/godot/fx-binbun-rebuild.ts)
	ALBEDO *= dm_gain;
	EMISSION *= dm_gain;
	ALPHA *= dm_fade;
}
