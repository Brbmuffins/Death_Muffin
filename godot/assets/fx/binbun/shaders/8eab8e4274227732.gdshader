shader_type spatial;

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
uniform float emission_strength = 2.0;

group_uniforms shape;
uniform sampler2D shape_texture;
uniform float shape_warp : hint_range(0.0, 1.0, 0.01) = 0.1;
uniform float open_amount : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float edge_softness : hint_range(0.0, 1.0, 0.01) = 0.5;

group_uniforms motion;
uniform float speed_scale : hint_range(0.0, 32.0, 0.01) = 1.0;

group_uniforms transparency;
uniform bool dither = false;

vec2 to_polar(vec2 uv) {
	float radius = length(uv);
	float angle = atan(uv.x, uv.y);
	return vec2(angle, radius) / PI;
}

float sample_shape(vec2 uv, float opened) {
	//uv = uv * 2.0 - 1.0;
	float dist = texture(shape_texture, uv).r;
	float depth_dist = clamp(dist / opened, 0.0, 1.0);
	return depth_dist;
}

float sample_noise(vec2 uv, float scale){
	uv = uv * (2.0 * scale) - (1.0 * scale);
	vec2 motion = vec2(TIME) * vec2(0.05, 0.1);
	motion *= speed_scale;
	uv = to_polar(uv) + motion;
	uv.x *= scale;
	float noise = texture(noise_texture, uv).r;
	return noise;
}

void vertex() {
	VERTEX += ((NORMAL * (pow(1.0 - sample_shape(UV, open_amount), 0.2) * 2.0 - 1.5)) * 0.4) * pow(open_amount, 8.0);
}

uniform float dm_gain = 1.0;
uniform float dm_fade = 1.0;
void fragment() {

	vec2 uv = UV;
	if(size.y < size.x){
		float aspect = size.y / size.x;
		uv = ((UV * 2.0 - 1.0) * vec2(1.0, aspect)) / 2.0 - 0.5;
	}else{
		float aspect = size.x / size.y;
		uv = ((UV * 2.0 - 1.0) * vec2(aspect, 1.0)) / 2.0 - 0.5;
	}

	uv = mod(uv, vec2(1.0));

	float shape = 1.0 - sample_shape(UV, pow(open_amount, 0.5));
	shape = clamp(shape * 2.4, 0.0, 1.0);

	float inner = 1.0 - sample_shape(UV, open_amount);
	float inner_mask = pow(clamp((inner - 0.43), 0.0, 1.0), 0.5) * 1.5;
	shape -= inner_mask;

	float noise_mult = sample_noise(uv, 3.0);
	float noise = sample_noise(uv * (1.0 - (noise_mult * shape_warp)), 1.0);

	float glow = clamp(shape - (1.0 - noise),0.0,1.0);
	glow = pow(glow, 1.0);
	float edge_min = mix(0.4,0.0,edge_softness);
	float edge_max = mix(0.4,1.0,edge_softness);

	float rim = pow(clamp(inner * 2.4, 0.0, 1.0), 3.0);
	rim -= inner_mask;
	rim = clamp((rim - 0.5) / 0.45, 0.0, 1.0);

	glow += rim * 0.5;
	glow = smoothstep(edge_min, edge_max, glow);

	vec3 color = mix(secondary_color, primary_color, glow).rgb;

	if(dither){
		if(glow < bayer4x4(FRAGCOORD)*2.0){
			discard;
		}
		color = floor(color / bayer4x4(FRAGCOORD));
	} else {
		if(glow < 0.01){
			discard;
		}else{
			ALPHA = glow;
		}
	}

	ALBEDO = mix(secondary_color, primary_color, glow).rgb;
	EMISSION = ALBEDO * emission_strength;

	// dm: gain/fade hooks (tools/godot/fx-binbun-rebuild.ts)
	ALBEDO *= dm_gain;
	EMISSION *= dm_gain;
	ALPHA *= dm_fade;
}
