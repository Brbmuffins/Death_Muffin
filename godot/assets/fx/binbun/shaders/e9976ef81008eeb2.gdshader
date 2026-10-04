shader_type spatial;
render_mode blend_mix, unshaded;

// begin util/freshnel.gdshaderinc
float fresnel(float amount, vec3 normal, vec3 view)
{
	return pow((1.0 - clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0 )), amount);
}

// end util/freshnel.gdshaderinc
// begin util/blend.gdshaderinc
float blendf(float a, float b, int mode){
	float result = 0.0;
	if(mode == 0) {result = a + b;} // Add
	if(mode == 1) {result = a - b;} // Sub
	if(mode == 2) {result = a * b;} // Mult
	if(mode == 3) {result = min(a, b);} // Darken
	if(mode == 4) {result = max(a, b);} // Lighten
	if(mode == 5) {result = 1.0 - (1.0 - a) * (1.0 - b);} // Screen
	if(mode == 6) {result =  a < 0.5 ? (2.0 * a * b) : (1.0 - 2.0 * (1.0 - a) * (1.0 - b));} // Overlay
	if(mode == 7) {result = b < 0.5 ? (2.0 * a * b) : (1.0 - 2.0 * (1.0 - a) * (1.0 - b));} // Hard Light
	if(mode == 8) {result = b < 0.5 ? (2.0 * a * b + a * a * (1.0 - 2.0 * b)) : (sqrt(a) * (2.0 * b - 1.0) + (2.0 * a) * (1.0 - b));} // Soft Light
	if(mode == 9) {result = a / (1.0 - b);} // Color Dodge
	if(mode == 10) {result = 1.0 - (1.0 - a) / b;} // Burn
	if(mode == 11) {result = a + b - 1.0;} // Burn
	return result;
}

// end util/blend.gdshaderinc
// begin util/alpha.gdshaderinc
// begin dithering.gdshaderinc
float bayer4x4(vec4 frag){
	ivec2 pixel = ivec2(frag.xy);
	int x = pixel.x & 3;
	int y = pixel.y & 3;
	int i = x + y * 4;
	float m[16] = float[](
		0.0, 8.0, 2.0, 10.0,
		12.0, 4.0, 14.0, 6.0,
		3.0, 11.0, 1.0, 9.0,
		15.0, 7.0, 13.0, 5.0
	);
	return (m[i] + 0.5) / 32.0;
}

// end dithering.gdshaderinc

const vec3 ign = vec3(0.06711056f, 0.00583715f, 52.9829189f);

bool alpha_discard(float value, vec4 frag, int mode, float d_cutoff, float a_cutoff){
	if(mode == 0){
		return false;
	} else if (mode == 1) {
		if(value < a_cutoff){
			return true;
		} else if (value < d_cutoff || value < fract(ign.z * fract(dot(frag.xy, ign.xy)))) {
			return true;
		}
	} else if (mode == 2) {
		if (value < a_cutoff){
			return true;
		}
	} else if (mode == 3) {
		if(value < a_cutoff){
			return true;
		} else if (value < d_cutoff){
			float rest = smoothstep(0.02, 0.5, value);
			if (rest < bayer4x4(frag)){
				return true;
			}
		}
	}
	return false;
}

// end util/alpha.gdshaderinc

group_uniforms fresnel;
uniform float fresnel_amount : hint_range(0.0, 5.0, 0.05) = 1.0;
uniform float fresnel_exponent = 1.0;
uniform sampler2D fresnel_gradient;

group_uniforms Mask;
uniform bool enable_mask = false;
uniform sampler2D mask_texture;
uniform vec2 mask_scroll = vec2(0.0);
uniform vec2 mask_scale = vec2(1.0);
uniform int mask_blend_mode : hint_range(0, 11, 1) = 0;
uniform float mask_blend : hint_range(0.0, 1.0, 0.1) = 0.0;

group_uniforms Emission;
uniform float emission_strength = 1.0;

group_uniforms color;
uniform vec4 primary_color : source_color;
uniform vec4 secondary_color : source_color;
uniform vec4 tertiary_color : source_color;

group_uniforms ProximityFade;
uniform bool proximity_fade = false;
uniform float proximity_fade_distance : hint_range(0.0, 4096.0, 0.01) = 1.0;

group_uniforms Transparency;
uniform float alpha_multiplier : hint_range(0.0, 1.0, 0.05) = 0.954;
uniform int alpha_mode : hint_range(0, 3, 1) = 0;
uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.05;
uniform float dither_cutoff : hint_range(0.0, 1.0, 0.01) = 0.8;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

void vertex() {
	// Called for every vertex the material is visible on.
}

uniform float dm_gain = 1.0;
uniform float dm_fade = 1.0;
void fragment() {
	float fres = fresnel(fresnel_amount, NORMAL, VIEW);
	float value = texture(fresnel_gradient, vec2(fres,0.0)).r;
	value = pow(value, fresnel_exponent);

	if(enable_mask){
		float mask_value = texture(mask_texture, (UV * mask_scale) + (vec2(TIME) * mask_scroll)).r;
		value = mix(value, blendf(value, mask_value, mask_blend_mode), mask_blend);
		value = clamp(value, 0.0, 1.0);
	}

	ALBEDO = mix(secondary_color, primary_color, value).rgb * emission_strength;

	float alpha = value * alpha_multiplier;

	// Proximity Fade: Enabled
	if(proximity_fade){
		float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		vec4 proximity_view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
		proximity_view_pos.xyz /= proximity_view_pos.w;
		alpha *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	}

	if(alpha_mode == 0){
		ALPHA = alpha;
	} else {
		if(alpha_discard(alpha, FRAGCOORD, alpha_mode, dither_cutoff, alpha_cutoff)){
			discard;
		}
	}

	// dm: gain/fade hooks (tools/godot/fx-binbun-rebuild.ts)
	ALBEDO *= dm_gain;
	EMISSION *= dm_gain;
	ALPHA *= dm_fade;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
