shader_type spatial;
render_mode blend_mix;

// begin util/dithering.gdshaderinc
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

// end util/dithering.gdshaderinc

uniform vec2 size = vec2(2.0,2.0);
uniform sampler2D noise_texture;

group_uniforms color;
uniform vec4 primary_color : source_color;
uniform vec4 secondary_color : source_color;
uniform float tint_amount : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float emission_strength = 2.0;

group_uniforms shape;
uniform sampler2D shape_texture;
uniform float shape_warp : hint_range(0.0, 1.0, 0.01) = 0.1;
uniform float open_amount : hint_range(0.0,1.0,0.01) = 1.0;
uniform float density : hint_range(0.0,1.0,0.01) = 0.4;
uniform float edge_softness : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float shrink_amount : hint_range(0.0, 1.0, 0.01) = 0.5;

group_uniforms depth;
uniform int layers : hint_range(0, 64, 1) = 8;
uniform float depth_amount = 1.0;
uniform float depth_mult = 1.0;
uniform float fade_amount : hint_range(0.0, 16.0, 0.01) = 1.0;
uniform float fade_mult = 1.0;

group_uniforms motion;
uniform float speed_scale : hint_range(0.0, 32.0, 0.01) = 1.0;
uniform float spin_motion = 0.5;
uniform float inward_motion = 1.0;
uniform float base_motion = 0.2;

group_uniforms portal;
uniform int portal_mode : hint_enum("Opaque", "Transparent", "Stencil") = 1;

uniform sampler2D screen_texture : hint_screen_texture;

group_uniforms transparency;
uniform bool dither = false;

vec2 to_polar(vec2 uv) {
	float radius = length(uv);
	float angle = atan(uv.x, uv.y);
	return vec2(angle / 2.0, radius) / PI;
}

float blend_overlay(float a, float b){
	float limit = step(0.5, a);
	return mix(2.0 * a * b, 1.0 - 2.0 * (1.0 - a) * (1.0 - b), limit);
}

vec2 parallax(float depth, vec3 n, vec3 t, vec3 v) {
	vec3 normal = normalize(n);
	vec3 tangent = normalize(t);
	vec3 bitangent = cross(normal, tangent);
	vec3 view = normalize(v);
	vec3 view_tangent = vec3(dot(view, tangent), dot(view, bitangent), dot(view, normal));
	vec2 offset = (view_tangent.xy / max(view_tangent.z, 0.001)) * depth;
	offset = vec2(-offset.x, offset.y);

	return offset;
}

float sample_shape(vec2 uv, float depth) {
	float dist = texture(shape_texture, uv).r;
	float depth_dist = clamp(dist / (open_amount - (depth * (shrink_amount * 1.0))), 0.0, 1.0);
	return depth_dist;
}

float sample_noise(vec2 uv , float depth, float scale){
	uv = uv * (2.0 * scale) - (1.0 * scale);
	vec2 motion = vec2(TIME) * vec2(depth + base_motion, depth + base_motion) * vec2(spin_motion, inward_motion);
	motion *= speed_scale;
	uv = (to_polar(uv) + vec2(depth, 0.0)) + motion;
	uv.x *= scale;
	float noise = texture(noise_texture, uv).r;
	return noise;
}

void vertex(){
	VERTEX += ((NORMAL * (pow(1.0 - sample_shape(UV, 0.0), 0.2) * 2.0 - 1.0)) * 0.2) * open_amount;
}

void fragment() {
	float value = 0.0;

	vec2 uv = UV;
	if(size.y < size.x){
		float aspect = size.y / size.x;
		uv = ((UV * 2.0 - 1.0) * vec2(1.0, aspect)) / 2.0 - 0.5;
	}else{
		float aspect = size.x / size.y;
		uv = ((UV * 2.0 - 1.0) * vec2(aspect, 1.0)) / 2.0 - 0.5;
	}

	uv = mod(uv, vec2(1.0));

	for(int i = 0; i < layers; i++){
		float t = (float(i) / float(layers));
		float depth = t * (depth_amount * depth_mult);

		vec2 circle_uv = UV + parallax(depth, NORMAL, TANGENT, VIEW);
		vec2 noise_uv = uv + parallax(depth, NORMAL, TANGENT, VIEW);

		float circle = sample_shape(circle_uv, t);
		circle = clamp((circle - (0.5 - density)) / (1.5 - density), 0.0, 1.0);

		float noise_mult = sample_noise(noise_uv, t, 2.0);
		float noise = sample_noise(noise_uv * (1.0 - (noise_mult * shape_warp)), t, 1.0);

		float shaped_circle = blend_overlay(circle, noise);
		float edge_min = mix(0.4, 0.8, 1.0 - edge_softness);
		float edge_max = mix(1.0, 0.8, 1.0 - edge_softness);
		shaped_circle = smoothstep(edge_min,edge_max,shaped_circle);

		float fade = pow(1.0 - t, (fade_amount * fade_mult));

		value = max(value, shaped_circle * fade);
	}

	float circle_value = sample_shape(UV, 0.0);

	vec3 color = mix(secondary_color.rgb, primary_color.rgb, value);

	float alpha = smoothstep(0.0, 0.5, 1.0 - circle_value);
	alpha = step(0.2,alpha);

	if(portal_mode == 1){
		vec2 warped_uv = SCREEN_UV * 2.0 - 1.0;
		warped_uv = warped_uv * (1.0 - (circle_value * 0.5));
		warped_uv = warped_uv * (1.0 - (pow(value, 4.0) * 2.0));
		warped_uv = warped_uv / 2.0 + 0.5;

		vec3 screen = textureLod(screen_texture, warped_uv, value * 1.0).rgb;
		screen.r = blend_overlay(screen.r, secondary_color.r);
		screen.g = blend_overlay(screen.g, secondary_color.g);
		screen.b = blend_overlay(screen.b, secondary_color.b);

		color = mix(screen, color, smoothstep(0.0, 0.7, value));
	}

	if(portal_mode == 2){
		alpha *= 1.0 - ((1.0 - value) * 0.5);
	}

	if(dither){
		if(alpha < bayer4x4(FRAGCOORD)*2.0){
			discard;
		}
		color = floor(color / bayer4x4(FRAGCOORD));
	} else {
		if(alpha < 0.01){
			discard;
		}else{
			ALPHA = alpha;
		}
	}

	ALBEDO = clamp(color, 0.0, 1.0);
	EMISSION = ALBEDO * emission_strength;
}
