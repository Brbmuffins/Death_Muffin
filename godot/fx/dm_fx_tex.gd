class_name DmFxTex
extends RefCounted
## Textures + shaders shared by the procedural effects. The sprites are the web's own pixels: fxTextures.ts canvas drawings baked by
## tools/godot/fx-textures.mjs to res://assets/fx/tex/<name>.png (glow ring disc sigil cone coneEdge bar smoke spark cracks
## lightPool) and the generated sprites res://assets/fx/art/<name>.webp (FX_IMAGES: skull, boneShard, crescent, ...).

const IMAGES := {
	"skull": "skull", "boneShard": "bone-shard", "bloodSigil": "blood-sigil", "frostFan": "frost-fan", "rime": "rime",
	"boneRing": "bone-ring", "crescent": "crescent", "seedBud": "seed-bud", "wisp": "wisp", "rallySigil": "rally-sigil",
	"veilStreak": "veil-streak", "graveOutline": "grave-outline", "crow": "crow", "hookChain": "hook-chain",
	"soundRing": "sound-ring", "lanternCone": "lantern-cone", "veilRift": "veil-rift", "tideCrest": "tide-crest",
	"drownedHand": "drowned-hand",
}
const PROCEDURAL := ["glow", "ring", "disc", "sigil", "cone", "coneEdge", "bar", "smoke", "spark", "cracks", "lightPool"]

static var _cache: Dictionary = {}
static var _shaders: Dictionary = {}


## fx.<name>() or fxImage(<name>).
static func get_tex(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	var path := ""
	if name in PROCEDURAL:
		path = "res://assets/fx/tex/%s.png" % name
	elif IMAGES.has(name):
		path = "res://assets/fx/art/%s.webp" % IMAGES[name]
	var t: Texture2D = load(path) as Texture2D if path != "" and ResourceLoader.exists(path) else null
	_cache[name] = t
	return t


## The texture's name (for outline profile / footprint lookups), "" when unknown.
static func name_of(t: Texture2D) -> String:
	if t == null:
		return ""
	var p := t.resource_path
	for n in PROCEDURAL:
		if p.ends_with("/tex/%s.png" % n):
			return n
	return p.get_file().get_basename()


const _BILLBOARD := """
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
"""

const _SRC := {
	# Effects.ts ParticleSystem: a billboard per mote, colour * texture, alpha from the instance colour.
	"particle": """
shader_type spatial;
render_mode BLEND, unshaded, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D tex : source_color, filter_linear;
void vertex() {
""" + _BILLBOARD + """
}
void fragment() {
	vec4 t = texture(tex, UV);
	float a = t.a * COLOR.a;
	if (a < 0.004) discard;
	ALBEDO = COLOR.rgb * t.rgb;
	ALPHA = a;
}
""",
	# DecalLayer: ground quad, tint = instance colour, INSTANCE_CUSTOM = (opacity, rim).
	"decal": """
shader_type spatial;
render_mode BLEND, unshaded, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic;
uniform float rim_edge = 2.0;
uniform float rim_floor = 1.0;
varying float v_op;
varying float v_rim;
void vertex() {
	v_op = INSTANCE_CUSTOM.x;
	v_rim = INSTANCE_CUSTOM.y;
}
void fragment() {
	vec4 t = texture(tex, UV);
	float a = t.a * v_op;
	if (v_rim > 0.0) {
		float rr = length(UV - 0.5) * 2.0;
		float inner = 1.0 - smoothstep(rim_edge - 0.06, rim_edge + 0.03, rr);
		a *= 1.0 - v_rim * inner * (1.0 - rim_floor);
	}
	if (a < 0.004) discard;
	ALBEDO = COLOR.rgb * t.rgb;
	ALPHA = a;
}
""",
	# SpriteLayer: billboard rotated about the view axis; INSTANCE_CUSTOM = (rot, opacity).
	"sprite": """
shader_type spatial;
render_mode BLEND, unshaded, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D tex : source_color, filter_linear;
varying float v_op;
void vertex() {
	v_op = INSTANCE_CUSTOM.y;
""" + _BILLBOARD + """
	float c = cos(INSTANCE_CUSTOM.x);
	float s = sin(INSTANCE_CUSTOM.x);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(c, s, 0.0, 0.0), vec4(-s, c, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
}
void fragment() {
	vec4 t = texture(tex, UV);
	float a = t.a * v_op;
	if (a < 0.002) discard;
	ALBEDO = COLOR.rgb * t.rgb;
	ALPHA = a;
}
""",
	# BeamLayer: flat tinted open tube, INSTANCE_CUSTOM.x = opacity.
	"beam": """
shader_type spatial;
render_mode BLEND, unshaded, depth_draw_never, cull_disabled, fog_disabled;
varying float v_op;
void vertex() {
	v_op = INSTANCE_CUSTOM.x;
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = v_op;
}
""",
}


## Shader for a layer kind ("particle" | "decal" | "sprite" | "beam"), additive or normal blending.
static func shader(kind: String, additive: bool) -> Shader:
	var key := "%s|%s" % [kind, additive]
	if _shaders.has(key):
		return _shaders[key]
	var s := Shader.new()
	s.code = String(_SRC[kind]).replace("BLEND", "blend_add" if additive else "blend_mix")
	_shaders[key] = s
	return s


static func material(kind: String, additive: bool, tex: Texture2D, priority: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader(kind, additive)
	if tex != null:
		m.set_shader_parameter("tex", tex)
	m.render_priority = priority
	return m
