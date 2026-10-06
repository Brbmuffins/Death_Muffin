class_name DmNextPerf
extends Node
## The rebuild's performance controls, the same behaviour DmGame has (`_pace`, `_apply_render_scale`, `_apply_graphics`):
##   graphics "low"  no moon shadows, no bloom, 3 prop lights instead of LIGHT_NEAR, halved atmosphere particles (Vfx.quality "low")
##   fps             Engine.max_fps (0 = uncapped)
##   auto_res        DmResolutionGovernor on the 3D view's scaling_3d_scale (the UI stays sharp); held through loads and area entries
## `apply(settings)` runs at start and whenever Settings change (DmNextUiHost). Prop culling, streaming and the shadow range are the
## builder's own (DmNextWorld.update calls them every frame, same cells and ranges as DmGame).

var game: Node3D
var governor := DmResolutionGovernor.new()
var settings: Dictionary = {}
var frame_ms := 16.7
var enabled := true            ## false = no pacing (headless / no renderer)
var _gfx_key := ""


func _ready() -> void:
	enabled = DisplayServer.get_name() != "headless"


func _exit_tree() -> void:
	Engine.max_fps = 0
	var vp := get_viewport()
	if vp != null:
		vp.scaling_3d_scale = 1.0


func apply(s: Dictionary) -> void:
	settings = s
	var high := String(s.get("graphics", "high")) != "low"
	var fps := int(s.get("fps", 0))
	Engine.max_fps = fps if fps > 0 else 0
	var vfx := get_node_or_null("/root/Vfx")
	if vfx != null:
		vfx.quality = "high" if high else "low"
	var world: DmNextWorld = game.get("world") if game != null else null
	if world != null:
		if world.builder != null:
			world.builder.moon.shadow_enabled = high
			world.builder.light_near = DmWorldBuilder.LIGHT_NEAR if high else 3
		if world.dressing != null:
			world.dressing.set_feature("bloom", high)
			if world.dressing.atmosphere != null:
				world.dressing.atmosphere.quality_low = not high
	# Only a graphics / fps / auto_res change restarts the governor at full resolution.
	var key := "%s|%d|%s" % [str(high), fps, str(s.get("auto_res", true))]
	if key != _gfx_key:
		_gfx_key = key
		governor.reset()
		governor.hold()
		_apply_render_scale()


## An area entry / scene load is not a GPU problem: slow frames around it must not step the resolution down.
func hold() -> void:
	governor.hold()


func _process(delta: float) -> void:
	if enabled and bool(game.get("ready_")):
		pace(delta)


## One frame of the governor (public so tests can feed a simulated frame stream).
func pace(delta: float) -> void:
	frame_ms += (delta * 1000.0 - frame_ms) * 0.1
	if not bool(settings.get("auto_res", true)):
		return
	if governor.frame(delta, frame_ms, DmResolutionGovernor.budget_fps(int(settings.get("fps", 0)))):
		_apply_render_scale()


func _apply_render_scale() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = governor.scale if bool(settings.get("auto_res", true)) else 1.0
