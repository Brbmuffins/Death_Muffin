class_name DmWfxBloom
extends RefCounted
## The web renderer's bloom (GameRuntime UnrealBloomPass, WorldScene.bloom = {strength 0.75, radius 0.55, threshold 0.85}) on Godot's glow. Mapping: additive blend; glow_intensity = strength;
## hdr threshold = threshold; the radius shapes the mip weights exactly like UnrealBloom's lerpBloomFactor (factor -> mix(factor, 1.2 - factor, radius)) over factors 1.0, 0.8, 0.6, 0.4, 0.2.
## high quality only (GameRuntime.bloomEnabled): apply(env, false) turns it off.
## Ported (client/code.list "Ported"): on Forward+ the same numbers glow much wider than they did on Compatibility. Measured with the look probe's glow part (`tools/look_probe.gd --part=glow`, 1280x720,
## a 6 m quad of albedo 2 and a 0.9 m emission of energy 6 on a dark stage; today's game and the rebuilt client in turn; red channel of the row outwards from a bright edge, every 6 px): the small emission, today's
## 247, 189, 103, 41, 15, then the background at 30 px; Forward+ with the web's five mips 255, 255, 251, 232, 213, 191 ... and still 88 of 255 at 66 px (Compatibility's glow is as narrow as if the coarse mips, 1/8 resolution and
## below, added nothing). The two finest mips (levels 0 and 1: half and quarter resolution) at 0.8 of the web's strength give 255, 210, 104, 15, then nothing at 24 px: today's reach (a log-radiance
## error of 0.1 to 0.2 over both objects, 2.0 to 2.8 for the five mips; adding the third mip at 0.05 made it 0.4 to 0.5). Threshold 0.85, scale 2 and the luminance cap of 12 are today's and stay: they move a
## glow's height, not its width.

const MIP_FACTORS := [1.0, 0.8, 0.6, 0.4, 0.2]
const LEVELS := 2            ## the glow's mips (levels 0 and 1 of 7: half and quarter resolution), the rest are 0
const GAIN := 0.8            ## of the web's strength

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
	env.glow_intensity = float(bloom.strength) * GAIN
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = float(bloom.threshold)
	env.glow_hdr_scale = 2.0
	env.glow_hdr_luminance_cap = 12.0
	var w := mip_weights(float(bloom.radius))
	for i in 7:
		env.set_glow_level(i, float(w[i]) if i < LEVELS else 0.0)
