class_name DmPerfOverlay
extends CanvasLayer
## F3 performance overlay, modelled on the web FpsOverlay: fps / avg / worst frame / hitches (>50 ms) over the last 5 s,
## p50 frame time, logic (process + physics) vs render CPU/GPU, draw calls, objects, primitives, memory.
## Numbers from a software renderer (llvmpipe) are meaningless for real hardware: compare on the player's PC.

const WINDOW_S := 5.0
const HITCH_MS := 50.0
var label: Label
var panel: PanelContainer
var _samples: Array = []   # [t, dt_ms]
var _last_paint := 0.0
var _vp: RID

func _ready() -> void:
	layer = 100
	panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.02, 0.05, 0.78)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.position.y = 8
	label = Label.new()
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_font_override("font", _mono())
	label.text = "measuring..."
	panel.add_child(label)
	add_child(panel)
	panel.visible = false
	_vp = get_viewport().get_viewport_rid()

func _mono() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["monospace", "DejaVu Sans Mono", "Consolas"])
	return f

func set_shown(on: bool) -> void:
	panel.visible = on
	RenderingServer.viewport_set_measure_render_time(_vp, on)
	_samples.clear()

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.physical_keycode == KEY_F3:
		set_shown(not panel.visible)
		get_viewport().set_input_as_handled()

func summary() -> Dictionary:
	var arr: Array = []
	var hitches := 0
	var worst := 0.0
	var sum := 0.0
	for s in _samples:
		arr.append(s[1])
		sum += s[1]
		worst = maxf(worst, s[1])
		if s[1] > HITCH_MS:
			hitches += 1
	if arr.is_empty():
		return {}
	arr.sort()
	var span := float(_samples[-1][0] - _samples[0][0])
	return {"fps": (arr.size() - 1) / maxf(span, 0.001) if arr.size() > 1 else 0.0, "avg": sum / arr.size(), "p50": arr[arr.size() / 2], "worst": worst, "hitches": hitches / WINDOW_S, "n": arr.size()}

func _process(dt: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_samples.append([now, dt * 1000.0])
	while _samples.size() > 1 and now - _samples[0][0] > WINDOW_S:
		_samples.pop_front()
	if not panel.visible or now - _last_paint < 0.25:
		return
	_last_paint = now
	var s := summary()
	if s.is_empty():
		return
	var calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var objs := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	var prims := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var tex := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
	var proc := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var cpu_r := RenderingServer.viewport_get_measured_render_time_cpu(_vp)
	var gpu_r := RenderingServer.viewport_get_measured_render_time_gpu(_vp)
	var vs := get_viewport().get_visible_rect().size
	var lines := [
		"%d fps   avg %.1f ms   p50 %.1f ms   worst %.1f ms   hitches %.1f/s (>%d ms)" % [int(round(s.fps)), s.avg, s.p50, s.worst, s.hitches, int(HITCH_MS)],
		"logic %.1f ms (process %.1f + physics %.1f)   render cpu %.1f ms   gpu %s" % [proc + phys, proc, phys, cpu_r, ("%.1f ms" % gpu_r) if gpu_r > 0.0 else "n/a"],
		"calls %d   objects %d   prims %s   tex %.0f MB   nodes %d" % [calls, objs, _kilo(prims), tex / 1048576.0, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))],
		"%s  %dx%d  mem %.0f MB  window 5 s (%d frames)" % [RenderingServer.get_video_adapter_name(), int(vs.x), int(vs.y), Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, s.n],
	]
	label.text = "\n".join(lines)

func _kilo(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1e6)
	if n >= 1000:
		return "%.1fk" % (n / 1e3)
	return str(n)
