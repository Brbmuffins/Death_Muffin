shader_type spatial;
render_mode unshaded, blend_add;

// begin ../../../shared/shader/util/uv_util.gdshaderinc
vec2 to_polar(vec2 uv)
{
	vec2 dir = uv - 0.5;
	float radius = length(dir) * 2.0;
	float angle = atan(dir.y, dir.x) * 1.0/(PI * 2.0);
	return vec2(angle, radius);
}

vec2 rotate(vec2 uv, vec2 pivot, float angle)
{
	mat2 rotation = mat2(vec2(sin(angle), -cos(angle)),
						vec2(cos(angle), sin(angle)));

	uv -= pivot;
	uv = uv * rotation;
	uv += pivot;
	return uv;
}

vec2 local_uv(vec2 screen_uv, vec4 node_clip){
	vec2 local_uv = (screen_uv * 2.0 - 1.0) * node_clip.w - node_clip.xy;

	return local_uv;
}

// end ../../../shared/shader/util/uv_util.gdshaderinc
// begin ../../../shared/shader/util/hsl_util.gdshaderinc
vec3 shift_hue(vec3 color, float shift) {
	vec3 gray = vec3(0.57735);
	vec3 projection = gray * dot(gray, color);
	vec3 U = color - projection;
	vec3 V = cross(gray, U);
	vec3 shifted = U * cos(shift * 2.0 * PI) + V * sin(shift * 2.0 * PI) + projection;
	return shifted;
}

// end ../../../shared/shader/util/hsl_util.gdshaderinc

uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform float emission = 2.0;
uniform float hue_variation : hint_range(0.0, 1.0, 0.01) = 0.05;

uniform float glow_amount : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float fade_bottom : hint_range(0.0, 1.0, 0.01) = 0.0;

uniform float bob_amount : hint_range(0.0, 1.0, 0.01) = 0.05;

uniform sampler2D noise_texture;

void vertex(){
	VERTEX.y += sin(TIME * 2.0) * bob_amount;
}

void fragment() {

	float fresnel = pow(dot(VIEW, NORMAL), 4.0);
	fresnel *= glow_amount;

	fresnel = smoothstep(0.0,1.0,fresnel);

	if(fade_bottom > 0.01){
		float fade = pow((1.0 - UV.y) * 2.0 - 1.0, 0.2);
		fresnel = mix(fresnel, fresnel * fade, fade_bottom);
	}

	ALPHA = clamp(fresnel, 0.0 ,1.0);

	vec3 color = mix(secondary_color, primary_color, fresnel);

	float noise = texture(noise_texture, UV).r;
	float hue = (noise * 2.0 - 1.0) * (min(UV.y, 1.0 - UV.y) * 2.0) * hue_variation;
	color = shift_hue(color, hue);
	ALBEDO = color * emission;
}
