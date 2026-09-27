shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D noise_texture;
uniform sampler2D glow_noise_texture;

uniform vec4 primary_color : source_color;
uniform vec4 tertiary_color : source_color;

uniform vec2 time_scale = vec2(1.0);
uniform vec2 texture_scale = vec2(1.0);
uniform float noise_scale = 1.0;

uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 4096.0, 0.01) = 1.0;

uniform int alpha_mode : hint_range(0, 2, 1) = 0;
const vec3 ign = vec3(0.06711056f, 0.00583715f, 52.9829189f);
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

float fresnel(float amount, vec3 normal, vec3 view)
{
	return pow((1.0 - clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0 )), amount);
}

float noise(vec2 uv){
	float uv_mask1 = pow(uv.y, 0.2);
	float uv_mask2 = pow(1.0-uv.y, 0.2);
	float uv_mask = min(uv_mask1, uv_mask2);

	vec2 noise_uv = (uv * texture_scale) + vec2(TIME) * time_scale;
	float noise = texture(noise_texture, noise_uv).r * uv_mask;
	return noise;
}

void vertex() {
	float n = noise(UV);
	n = pow(n, 0.5);

	vec3 offset = (NORMAL * n);

	VERTEX += offset * noise_scale;
}

void fragment() {
	ROUGHNESS = 1.0;

	float glow_amount = COLOR.r;

	float glow_n = texture(glow_noise_texture, UV + vec2(TIME) * time_scale * 0.5).r;
	float n = pow(1.0 - noise(UV), 0.5) * (mix(glow_n, 1.0, .7));
	float glow = smoothstep(1.0 - glow_amount, 1.0, n);

	vec4 color = mix(tertiary_color, primary_color, glow);

	ALBEDO = color.rgb;
	EMISSION = (ALBEDO * 4.0) * glow;

	// ALPHA
	float decay_amount = 1.0 - COLOR.a;
	float alpha = smoothstep(decay_amount - 0.2, decay_amount, glow_n*0.8);//
	alpha *= 1.0 - fresnel(3.0, NORMAL, VIEW);


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
