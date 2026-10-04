shader_type spatial;
render_mode unshaded, blend_mix;

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

uniform float flare_streaks = 20.0;
uniform float flare_ring : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform float flare_amount : hint_range(0.0, 1.0, 0.01) = 1.0;


uniform bool billboard = true;

uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;

uniform sampler2D noise_texture;

void vertex() {
	if(billboard){
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
}

uniform float dm_gain = 1.0;
uniform float dm_fade = 1.0;
void fragment() {
	vec2 polar_uv = to_polar(UV);

	float view_offset = (NORMAL.x * 4.0);

	float gradient_01 = sin((polar_uv.x * PI * (flare_streaks * 0.4)) + view_offset + TIME);
	float gradient_02 = -sin((polar_uv.x * PI * flare_streaks) - view_offset - TIME);

	float value = clamp(gradient_01 * gradient_02, 0.0, 1.0);

	float flare_mask = pow(max(sin(polar_uv.y * PI),0.0), 8.0);

	value = pow(value, polar_uv.y * 2.0);

	float ledge = 0.4 * edge_hardness;
	float redge = mix(1.0, 0.41, edge_hardness);
	value = smoothstep(ledge, redge, value);
	value *= flare_mask;

	float ring = max(1.0 - abs(polar_uv.y * 2.0 - 1.0),0.0);
	ring *= ring * ring * ring;

	value += ring * flare_ring;
	value *= flare_amount;


	ALPHA = value * 0.2;

	vec3 color = mix(secondary_color, primary_color, value);

	float noise = texture(noise_texture, UV).r;
	float hue = (noise * 2.0 - 1.0) * hue_variation;
	color = shift_hue(color, hue);

	ALBEDO = color * emission;

	// dm: gain/fade hooks (tools/godot/fx-binbun-rebuild.ts)
	ALBEDO *= dm_gain;
	EMISSION *= dm_gain;
	ALPHA *= dm_fade;
}
