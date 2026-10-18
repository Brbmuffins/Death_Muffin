class_name DmNextPerf
extends Node
## The performance controls of the rebuilt client (DECISIONS B45): graphics preset,
## render scale, fps cap, auto-resolution.
##   graphics        preset (DmGraphicsPreset: low / medium / high / ultra): moon shadows + reach + atlas + soft filter, bloom, ambient occlusion, the crowd's shadow
##                   policy, MSAA / anisotropy / mesh LOD on the viewport, Vfx.quality + Binbun, the governor's resolution floor (0.6 Low, 0.85 above)
##   brightness      Settings -> Brightness x the preset's lift factor (on the area's lift), as the builder's exposure multiplier;  ui_scale  Interface size (window content scale)
##   fps             Engine.max_fps (0 = uncapped);  vsync  display V-Sync on / off (live, windowed builds only)
##   auto_res        DmResolutionGovernor on the 3D view's scaling_3d_scale, upscaled with FSR 1 (the UI stays sharp); held through loads and area entries
## There is no moon-shadow caster poll (the crowd keeps its own nearest-casters budget, DmCrowd.set_shadow_policy), no prop-light count or prop shadow range
## (baked into the area's lightmap). `apply(settings)` runs at the game's start (DmNextGame: the player's settings file, read only, until the Settings panel comes
## with the panels) and whenever settings change.

var game: Node3D
var governor := DmResolutionGovernor.new()
var settings: Dictionary = {}
var preset := DmGraphicsPreset.DEFAULT     ## the preset in force (normalized)
var frame_ms := 16.7
var enabled := true            ## false = no pacing (headless / no renderer)
var _gfx_key := ""
var _window_mode := ""


func _ready() -> void:
	enabled = DisplayServer.get_name() != "headless"


func _exit_tree() -> void:
	Engine.max_fps = 0
	var vp := get_viewport()
	if vp != null:
		vp.scaling_3d_scale = 1.0


func apply(s: Dictionary) -> void:
	settings = s
	preset = DmGraphicsPreset.normalize(s.get("graphics", DmGraphicsPreset.DEFAULT))
	var gp := DmGraphicsPreset.get_preset(preset)
	var fps := int(s.get("fps", 0))
	var win := get_window()
	if win != null and enabled:
		win.content_scale_factor = DmSettings.clamp_ui_scale(s.get("ui_scale", 1.0))   # Interface size, on top of the project's canvas_items stretch
	Engine.max_fps = fps if fps > 0 else 0
	if enabled:
		_apply_window_mode(DmSettings.clamp_window_mode(s.get("window_mode", "windowed")))
		_apply_vsync(bool(s.get("vsync", true)))
	var vfx := get_node_or_null("/root/Vfx")
	if vfx != null:
		vfx.quality = String(gp["fx"])
		if vfx.binbun != null:
			vfx.binbun.enabled = bool(gp["binbun"]) and String(gp["fx"]) == "high"   # the quality setter alone would switch it on for every "high" fx (Medium has none)
	var world: Node = game.get("world") if game != null else null
	var b: DmWorldBuilder = world.get("builder") if world != null else null
	if b != null:
		b.moon.shadow_enabled = bool(gp["shadows"])
		b.moon.directional_shadow_max_distance = float(gp["shadow_dist"])
		b.moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if int(gp["shadow_splits"]) == 2 else DirectionalLight3D.SHADOW_ORTHOGONAL
		b.set_preset_lift(float(gp["lift"]))                       # the preset's own factor on the area's lift (Low's moon casts no shadow)
		b.set_brightness(float(s.get("brightness", 1.0)))          # Settings -> Brightness
		if b.env != null:
			DmGraphicsPreset.apply_environment(b.env, preset)
	var dressing: DmWorldDressing = world.get("dressing") if world != null else null
	if dressing != null and dressing.atmosphere != null:
		dressing.atmosphere.quality_low = String(gp["fx"]) == "low"   # the weather thins on Low
	var host: Node = game.get("core_host") if game != null else null
	var view: CrowdView = host.get("view") if host != null else null
	if view != null and view.crowd != null:
		view.set_shadow_policy(int(gp["casters"]), int(gp["casters_crowd"]), bool(gp["thralls_cast"]))   # (the benchmark may override whether thralls cast)
		if b != null and b.moon != null and b.moon.is_inside_tree():
			view.set_light_direction(-b.moon.global_transform.basis.z)   # the crowd keeps a casting body just outside the view while its shadow falls in
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


## Settings -> V-Sync (on by default): off lets frames present as soon as they are drawn (tearing possible, lower input delay). Only acts on a change.
func _apply_vsync(on: bool) -> void:
	var mode := DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED
	if DisplayServer.window_get_vsync_mode() != mode:
		DisplayServer.window_set_vsync_mode(mode)


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
	var s := governor.scale if bool(settings.get("auto_res", true)) else 1.0
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if s < 0.999 else Viewport.SCALING_3D_MODE_BILINEAR   # FSR 1 sharpens an upscale; at full size nothing scales
	vp.scaling_3d_scale = s
