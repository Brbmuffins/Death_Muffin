class_name DmNextPerf
extends Node
## The performance controls (graphics preset, render scale, fps cap, auto-resolution):
##   graphics        preset (DmGraphicsPreset: low / medium / high / ultra): moon shadows + reach + atlas + soft filter, bloom, prop lights, prop shadow range,
##                   MSAA / anisotropy / mesh LOD on the viewport, Vfx.quality + Binbun, the governor's resolution floor (0.6 Low, 0.85 above)
##   brightness      Settings -> Brightness x the preset's lift, as the builder's exposure multiplier;  ui_scale  Interface size (window content scale)
##   fps             Engine.max_fps (0 = uncapped)
##   auto_res        DmResolutionGovernor on the 3D view's scaling_3d_scale (the UI stays sharp); held through loads and area entries
## Moon shadow casters: the nearest enemies only (DmCasterBudget, polled 2 Hz; counts per preset).
## `apply(settings)` runs at start and whenever Settings change (DmNextUiHost). Prop culling, streaming and the shadow range are the
## builder's own (DmNextWorld.update calls them every frame, same cells and ranges).

const CASTER_POLL_S := 0.5

var game: Node3D
var governor := DmResolutionGovernor.new()
var settings: Dictionary = {}
var frame_ms := 16.7
var enabled := true            ## false = no pacing (headless / no renderer)
var _gfx_key := ""
var _window_mode := ""
var _caster_t := 0.0


func _ready() -> void:
	enabled = DisplayServer.get_name() != "headless"


func _exit_tree() -> void:
	Engine.max_fps = 0
	var vp := get_viewport()
	if vp != null:
		vp.scaling_3d_scale = 1.0


func apply(s: Dictionary) -> void:
	settings = s
	var preset := DmGraphicsPreset.normalize(s.get("graphics", DmGraphicsPreset.DEFAULT))
	var gp := DmGraphicsPreset.get_preset(preset)
	var fps := int(s.get("fps", 0))
	var win := get_window()
	if win != null:
		win.content_scale_factor = DmSettings.clamp_ui_scale(s.get("ui_scale", 1.0))   # Interface size, on top of the project's canvas_items stretch
	Engine.max_fps = fps if fps > 0 else 0
	if enabled:
		_apply_window_mode(DmSettings.clamp_window_mode(s.get("window_mode", "windowed")))
	var vfx := get_node_or_null("/root/Vfx")
	if vfx != null:
		vfx.quality = String(gp["fx"])
		if vfx.binbun != null:
			vfx.binbun.enabled = bool(gp["binbun"]) and String(gp["fx"]) == "high"   # the quality setter alone would switch it on for every "high" fx (Medium has none)
	var world: DmNextWorld = game.get("world") if game != null else null
	if world != null:
		if world.builder != null:
			var b := world.builder
			b.moon.shadow_enabled = bool(gp["shadows"])
			b.light_near = int(gp["lights"])
			b.set_preset_lift(float(gp["lift"]))                       # Low/Medium run hotter to read as bright as High
			b.set_brightness(float(s.get("brightness", 1.0)))          # Settings -> Brightness
			b.shadow_range = float(gp["prop_shadow"])
			b.moon.directional_shadow_max_distance = float(gp["shadow_dist"])
			b.moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if int(gp["shadow_splits"]) == 2 else DirectionalLight3D.SHADOW_ORTHOGONAL
		if world.dressing != null:
			world.dressing.set_feature("bloom", bool(gp["bloom"]))
			if world.dressing.atmosphere != null:
				world.dressing.atmosphere.quality_low = String(gp["fx"]) == "low"
	var vp := get_viewport()
	if vp != null:
		DmGraphicsPreset.apply_render(vp, preset)
	governor.set_floor(float(gp["floor"]))
	# Only a graphics / fps / auto_res change restarts the governor at full resolution.
	var key := "%s|%d|%s" % [preset, fps, str(s.get("auto_res", true))]
	if key != _gfx_key:
		_gfx_key = key
		governor.reset()
		governor.hold()
		_apply_render_scale()


## Settings -> Window mode: windowed, borderless (a frameless window covering the whole screen) or exclusive fullscreen. Only acts on a change.
func _apply_window_mode(mode: String) -> void:
	if mode == _window_mode:
		return
	var first := _window_mode == ""
	_window_mode = mode
	if first and mode == "windowed":
		return   # the project's own window, untouched
	var screen := DisplayServer.window_get_current_screen()
	match mode:
		"fullscreen":
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		"borderless":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			DisplayServer.window_set_position(DisplayServer.screen_get_position(screen))
			DisplayServer.window_set_size(DisplayServer.screen_get_size(screen))
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			var size := DisplayServer.screen_get_size(screen)
			var win_size := Vector2i(mini(1280, size.x), mini(720, size.y))
			DisplayServer.window_set_size(win_size)
			DisplayServer.window_set_position(DisplayServer.screen_get_position(screen) + (size - win_size) / 2)


## An area entry / scene load is not a GPU problem: slow frames around it must not step the resolution down.
func hold() -> void:
	governor.hold()


func _process(delta: float) -> void:
	if not bool(game.get("ready_")):
		return
	_caster_t -= delta
	if _caster_t <= 0.0:
		_caster_t = CASTER_POLL_S
		update_casters()
	if enabled:
		pace(delta)


## Moon shadow caster budget (DmCasterBudget): the nearest enemies to the hero cast, the rest do not. Public so tests can call it.
func update_casters() -> void:
	var gp := DmGraphicsPreset.get_preset(settings.get("graphics", DmGraphicsPreset.DEFAULT))
	var hero: Node3D = game.get("player") as Node3D
	var pos := hero.global_position if hero != null and hero.is_inside_tree() else Vector3.ZERO
	DmCasterBudget.update(get_tree().get_nodes_in_group(&"dm_enemy"), pos.x, pos.z, int(gp["casters"]), int(gp["casters_crowd"]))


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
