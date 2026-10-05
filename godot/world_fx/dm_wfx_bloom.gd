class_name DmWfxBloom
extends RefCounted
## The web renderer's bloom (GameRuntime UnrealBloomPass, WorldScene.bloom = {strength 0.75, radius 0.55, threshold 0.85}) on Godot's glow
## (gl_compatibility). Mapping: additive blend; glow_intensity = strength; hdr threshold = threshold; the radius shapes the five mip weights
## exactly like UnrealBloom's lerpBloomFactor (factor -> mix(factor, 1.2 - factor, radius)) over factors 1.0, 0.8, 0.6, 0.4, 0.2.
## high quality only (GameRuntime.bloomEnabled): apply(env, false) turns it off.

const MIP_FACTORS := [1.0, 0.8, 0.6, 0.4, 0.2]

static func mip_weights(radius: float) -> Array:
	var w: Array = []
	for f in MIP_FACTORS:
		w.append(lerpf(f, 1.2 - f, radius))
	return w

## b = {strength, radius, threshold}. Defaults to the world scene's.
static func apply(env: Environment, enabled: bool = true, b: Dictionary = {}) -> void:
	if env == null:
		return
	var bloom: Dictionary = b if not b.is_empty() else DmWfxData.get_data().get("bloom", {"strength": 0.75, "radius": 0.55, "threshold": 0.85})
	env.glow_enabled = enabled
	if not enabled:
		return
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_intensity = float(bloom.strength)
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = float(bloom.threshold)
	env.glow_hdr_scale = 2.0
	env.glow_hdr_luminance_cap = 12.0
	var w := mip_weights(float(bloom.radius))
	for i in 7:
		env.set_glow_level(i, float(w[i]) if i < w.size() else 0.0)
