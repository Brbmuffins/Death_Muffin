shader_type spatial;
render_mode blend_mix, cull_disabled;

uniform sampler2D ring_texture;
uniform sampler2D noise_texture;

uniform vec4 primary_color : source_color;
uniform vec4 secondary_color : source_color;

uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 4096.0, 0.01) = 1.0;

uniform int alpha_mode : hint_range(0, 2, 1) = 0;
const vec3 ign = vec3(0.06711056f, 0.00583715f, 52.9829189f);
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;


void vertex() {
	// Called for every vertex the material is visible on.
}

float noise_fade(float v, float n, float amt, float treshold){
	float value = 1.0;
	float n_amt = amt * 2.0;

	value = mix(v, v - (1.0-(n * treshold)), n_amt);
	value = clamp(value, 0.0, 1.0);

	return value;
}

void fragment() {
	float ring_mask = texture(ring_texture, UV).r;
	float noise = texture(noise_texture, UV).r;
	float decay = (1.0 - pow(COLOR.a,0.5)) * 3.0;

	float value = noise_fade(ring_mask, noise, decay, 0.7);

	vec4 color = mix(secondary_color, primary_color, value);

	ALBEDO = mix(color.rgb, vec3(1.0), pow(COLOR.a, 8.0));
	EMISSION = ALBEDO * 2.0;

	float alpha = smoothstep(0.1,0.5, value);

	// Proximity Fade: Enabled
	if(proximity_fade){
		float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		vec4 proximity_view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
		proximity_view_pos.xyz /= proximity_view_pos.w;
		alpha *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	}

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
