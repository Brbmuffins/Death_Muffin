class_name DmGraphicsPreset
extends RefCounted
## Settings -> Graphics presets (Low / Medium / High / Ultra): one table, so the Settings panel, DmGame._apply_graphics, the resolution governor
## and the tests read the same numbers. The setting value is the preset id ("low"/"medium"/"high"/"ultra"); the old two-value setting
## ("high"/"low") is already a valid id, so saved settings migrate as they are. High keeps the old High's cost (owner: performance first) plus
## the 0.85 floor and anisotropic textures; MSAA and the heavy extras are opt-in on Ultra until real-GPU numbers say High can carry MSAA
## (on llvmpipe MSAA 2x made the rendered QA run time out; a real GPU is unmeasured). Anything unknown becomes High (the default for new players).
## Renderer stays gl_compatibility; MSAA / anisotropy are set on the viewport at runtime (project.godot is not touched). Forward+ is not a preset: see
## REBUILD.md Phase 6.
##   shadows/bloom  moon shadow + the bloom glow         lights   prop lights lit at once (DmWorldBuilder.light_near)
##   msaa           0 / 2 / 4 / 8 samples on the 3D view  aniso    anisotropic filtering level (floor + ground-marking textures at grazing angles)
##   floor          lowest 3D scale Auto resolution may drop to   fx   DmFx quality ("low" thins bursts and drops the Binbun layer)
##   binbun         the premium Binbun VFX layer          shadow_size / shadow_dist / prop_shadow (props further than this stop casting) / shadow_splits / soft   directional shadow atlas size, how far the moon's
##   shadows reach, PSSM splits (2 = sharper near the hero), soft-shadow filter (0 low .. 3 ultra)   lod  mesh LOD threshold (0.5 = detail holds longer)
##   lift           exposure multiplier that keeps a preset as bright as High (fewer prop lights, no bloom: measured with tests/perf/lighting_shot.sh)

const DEFAULT := "high"
const IDS: Array[String] = ["low", "medium", "high", "ultra"]
const LABELS := {
	"low": "Low (fastest)",
	"medium": "Medium (shadows)",
	"high": "High (bloom, sharp textures)",
	"ultra": "Ultra (more lights, long sharp shadows, 4x smoothing)",
}
const TABLE := {
	"low": {"lift": 1.4, "shadows": false, "bloom": false, "lights": 3, "msaa": 0, "aniso": 2, "floor": 0.6, "fx": "low", "binbun": false,
		"shadow_size": 2048, "shadow_dist": 45.0, "prop_shadow": 32.0, "shadow_splits": 1, "soft": 0, "lod": 1.0},
	"medium": {"lift": 1.38, "shadows": true, "bloom": false, "lights": 5, "msaa": 0, "aniso": 4, "floor": 0.85, "fx": "high", "binbun": false,
		"shadow_size": 2048, "shadow_dist": 45.0, "prop_shadow": 32.0, "shadow_splits": 1, "soft": 1, "lod": 1.0},
	"high": {"lift": 1.0, "shadows": true, "bloom": true, "lights": 8, "msaa": 0, "aniso": 8, "floor": 0.85, "fx": "high", "binbun": true,
		"shadow_size": 2048, "shadow_dist": 45.0, "prop_shadow": 32.0, "shadow_splits": 1, "soft": 1, "lod": 1.0},
	"ultra": {"lift": 1.0, "shadows": true, "bloom": true, "lights": 14, "msaa": 4, "aniso": 16, "floor": 0.85, "fx": "high", "binbun": true,
		"shadow_size": 4096, "shadow_dist": 80.0, "prop_shadow": 56.0, "shadow_splits": 2, "soft": 3, "lod": 0.5},
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


## Viewport + RenderingServer side of a preset (the world / fx side is DmGame._apply_graphics).
static func apply_render(vp: Viewport, id: Variant) -> void:
	var p := get_preset(id)
	vp.msaa_3d = msaa_mode(int(p["msaa"]))
	vp.anisotropic_filtering_level = aniso_mode(int(p["aniso"]))
	vp.mesh_lod_threshold = float(p["lod"])
	RenderingServer.directional_shadow_atlas_set_size(int(p["shadow_size"]), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(int(p["soft"]) as RenderingServer.ShadowQuality)
	RenderingServer.positional_soft_shadow_filter_set_quality(int(p["soft"]) as RenderingServer.ShadowQuality)
