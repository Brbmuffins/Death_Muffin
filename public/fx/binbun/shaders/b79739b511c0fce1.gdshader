shader_type spatial;
render_mode blend_mix;

uniform sampler2D shape_texture;
uniform sampler2D noise_texture;

uniform vec4 primary_color : source_color;
uniform vec4 secondary_color : source_color;

uniform float decay : hint_range(0.0,1.0,0.01);

uniform int alpha_mode : hint_range(0, 2, 1) = 0;
const vec3 ign = vec3(0.06711056f, 0.00583715f, 52.9829189f);
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;


float shape(vec2 uv){
	float s = texture(shape_texture, uv).r;
	return s;
}

float wave(vec2 uv){
	float s = pow(shape(uv),0.4);
	float mask1 = shape(uv);
	float mask2 = pow(1.0 - shape(uv),2.0);
	float w = sin(s * 16.0 + (TIME * 16.0));
	w = (w + 1.0) / 2.0;
	w *= mask1 - pow(1.0 - decay, 8.0);
	w *= 1.0 + mask2 - pow(decay * 2.0, 1.0);
	w = clamp(w, 0.0, 1.0);
	return w * 8.0;
}

void vertex() {
	VERTEX += NORMAL * wave(UV) * 0.1;
}

void fragment() {
	float wave_value = wave(UV);

	float noise = texture(noise_texture, UV).r;

	float alpha = clamp(wave_value - noise, 0.0, 1.0);

	vec3 color = mix(secondary_color, primary_color, wave_value).rgb;

	ALBEDO = color;

	if(alpha_mode == 0){
		ALPHA = alpha;
	} else if (alpha_mode == 1) {
		if (alpha < 0.001 || alpha < fract(ign.z * fract(dot(FRAGCOORD.xy, ign.xy)))) {
			discard;
		}
	} else if (alpha_mode == 2) {
		if (alpha < 0.2){
			discard;
		}
	}
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
