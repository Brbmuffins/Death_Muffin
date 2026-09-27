shader_type spatial;
stencil_mode write, compare_always, 1;

uniform sampler2D shape_texture;

uniform float open_amount : hint_range(0.0, 1.0, 0.01) = 1.0;

void fragment() {
	float shape = texture(shape_texture, UV).r;
	shape = clamp(shape / (open_amount), 0.0, 1.0);

	if(shape > 0.85){
		discard;
	}
	ALPHA = 0.0;
}
