class_name DmGraphicsPreset
extends RefCounted
## Settings -> Graphics presets (Low / Medium / High / Ultra) of the rebuilt client on Forward+
## (DECISIONS B45): one table, so DmNextPerf, the resolution governor, the benchmark and the tests read the same numbers. The setting value is the preset id, the same
## ids as the old game's, so a player's saved setting carries over; anything unknown becomes High (the default for new players).
## What changed against the old game's table, and why (each a cost Forward+ handles differently from Compatibility):
##   - no `lights`: the prop lights are baked into the area's lightmap (client/areas/<id>.lmbake) and Forward+ draws the rest in clusters, so every preset keeps them all;
##     no `prop_shadow` either (the props' shadows are in the bake).
##   - crowd shadows are the crowd's own policy (DmCrowd.set_shadow_policy: the nearest `casters` enemies cast, `casters_crowd` once the field is crowded, thralls when
##     `thralls_cast`), not a node budget: same counts as the old game's DmCasterBudget.
##   - `ssao`: screen-space ambient occlusion, Forward+ only (0 off, 1 medium, 2 high): High and Ultra. Contact shadows where bodies stand and props meet the floor.
##   - the governor's lower resolutions are upscaled with FSR 1 (sharpened) instead of bilinear, which Compatibility could not do.
## The brightness lift is Forward+'s own and belongs to the area, not to the preset (`DmWorldBuilder.AREA_LIFT`: one exposure multiplier per area, measured against the old game on the same camera, Ultra,
## software Vulkan against software OpenGL; client/README.md "The look on Forward+"). Every preset keeps every light (they are baked) and a preset changes nothing else the eye reads as light,
## so Medium, High and Ultra share it (`lift` 1), except Low, whose moon casts no shadow (a little brighter): its factor is 0.96 of the area's.
##   shadows/bloom  moon shadow + the bloom glow         msaa   0 / 2 / 4 / 8 samples on the 3D view     aniso  anisotropic filtering level
##   floor          lowest 3D scale Auto resolution may drop to   fx   DmFx quality ("low" thins bursts and drops the Binbun layer)   binbun  the Binbun VFX layer
##   shadow_size / shadow_dist / shadow_splits / soft   the moon's shadow atlas size, reach, PSSM splits (2 = sharper near the hero), soft-shadow filter (0 low .. 3 ultra)
##   casters / casters_crowd / thralls_cast   the crowd's shadow policy (above)       ssao   (above)       lod   mesh LOD threshold (0.5 = detail holds longer)
##   lift           the preset's own factor on the area's exposure lift (above): 1, Low 0.96

const DEFAULT := "high"
const LIFT_LOW := 0.96    ## Low's factor on the area's lift: no moon shadow (above)
const IDS: Array[String] = ["low", "medium", "high", "ultra"]
const LABELS := {
	"low": "Low (fastest)",
	"medium": "Medium (shadows)",
	"high": "High (bloom, ambient occlusion, sharp textures)",
	"ultra": "Ultra (long sharp shadows, 4x smoothing)",
}
const TABLE := {
	"low": {"lift": LIFT_LOW, "shadows": false, "bloom": false, "ssao": 0, "msaa": 0, "aniso": 2, "floor": 0.6, "fx": "low", "binbun": false,
		"casters": 0, "casters_crowd": 0, "thralls_cast": false, "shadow_size": 2048, "shadow_dist": 45.0, "shadow_splits": 1, "soft": 0, "lod": 1.0},
	"medium": {"lift": 1.0, "shadows": true, "bloom": false, "ssao": 0, "msaa": 0, "aniso": 4, "floor": 0.85, "fx": "high", "binbun": false,
		"casters": 8, "casters_crowd": 6, "thralls_cast": true, "shadow_size": 2048, "shadow_dist": 45.0, "shadow_splits": 1, "soft": 1, "lod": 1.0},
	"high": {"lift": 1.0, "shadows": true, "bloom": true, "ssao": 1, "msaa": 0, "aniso": 8, "floor": 0.85, "fx": "high", "binbun": true,
		"casters": 12, "casters_crowd": 8, "thralls_cast": true, "shadow_size": 2048, "shadow_dist": 45.0, "shadow_splits": 1, "soft": 1, "lod": 1.0},
	"ultra": {"lift": 1.0, "shadows": true, "bloom": true, "ssao": 2, "msaa": 4, "aniso": 16, "floor": 0.85, "fx": "high", "binbun": true,
		"casters": 20, "casters_crowd": 14, "thralls_cast": true, "shadow_size": 4096, "shadow_dist": 80.0, "shadow_splits": 2, "soft": 3, "lod": 0.5},
}


static func normalize(id: Variant) -> String:
	var s := str(id)
	return s if TABLE.has(s) else DEFAULT


static func get_preset(id: Variant) -> Dictionary:
	return TABLE[normalize(id)]


static func options() -> Array:
	var out := []
	for id in IDS:
		out.append([id, LABELS[id]])
	return out


static func msaa_mode(samples: int) -> int:
	match samples:
		2:
			return Viewport.MSAA_2X
		4:
			return Viewport.MSAA_4X
		8:
			return Viewport.MSAA_8X
	return Viewport.MSAA_DISABLED


static func aniso_mode(level: int) -> int:
	match level:
		2:
			return Viewport.ANISOTROPY_2X
		4:
			return Viewport.ANISOTROPY_4X
		8:
			return Viewport.ANISOTROPY_8X
		16:
			return Viewport.ANISOTROPY_16X
	return Viewport.ANISOTROPY_DISABLED


## The soft-shadow filter quality (`soft` 0..3) as the RenderingServer's.
static func soft_quality(level: int) -> int:
	match level:
		1:
			return RenderingServer.SHADOW_QUALITY_SOFT_LOW
		2:
			return RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM
		3:
			return RenderingServer.SHADOW_QUALITY_SOFT_HIGH
	return RenderingServer.SHADOW_QUALITY_HARD


## Viewport + RenderingServer side of a preset (the world / crowd / fx side is DmNextPerf.apply).
static func apply_render(vp: Viewport, id: Variant) -> void:
	var p := get_preset(id)
	vp.msaa_3d = msaa_mode(int(p["msaa"]))
	vp.anisotropic_filtering_level = aniso_mode(int(p["aniso"]))
	vp.mesh_lod_threshold = float(p["lod"])
	RenderingServer.directional_shadow_atlas_set_size(int(p["shadow_size"]), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(soft_quality(int(p["soft"])))


## The environment side: bloom (DmWfxBloom) and, on Forward+, screen-space ambient occlusion.
static func apply_environment(env: Environment, id: Variant) -> void:
	var p := get_preset(id)
	DmWfxBloom.apply(env, bool(p["bloom"]))
	var ssao := int(p["ssao"])
	env.ssao_enabled = ssao > 0
	if ssao > 0:
		RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_HIGH if ssao >= 2 else RenderingServer.ENV_SSAO_QUALITY_MEDIUM, ssao < 2, 0.5, 2, 50.0, 300.0)
