class_name DmBenchmarkScreen
extends Control
## Benchmark UI around DmBenchmark: a progress line over the running fight (Esc cancels), then the results panel (big avg fps and p95 ms per
## phase, the full table with a "vs last run" column, the budget section, Copy to clipboard, Back / Quit). Also prints the report to the log ("BENCHMARK" prefix), saves it,
## records the run in DmBenchHistory and sends the queued runs to the benchmark history of the TEST server with `api` (online and logged in; else they wait). Ported to the
## rebuilt client (client/code.list "Ported"): the budget section is new; the transport behind `api` refuses any address but the test server's (net/dm_config.gd).
## `quit_on_close` (launch arg `--benchmark`): the closing button is "Quit" and quits the game (a headless run quits by itself once the report is out); otherwise `closed` is emitted (back to character select).

signal closed

var quit_on_close := false
var setup: Dictionary = DmBenchmark.STANDARD.duplicate()
var warm_s := -1.0               ## > 0: overrides the length's warm-up / measured seconds (`--bench-warm=` / `--bench-measure=` smoke runs)
var measure_s := -1.0
var api: DmApi                   ## the logged-in online api (uploads, to the test server); null = the run is queued until a later session sends it
var baked_dir := ""              ## where the baked crowd models are ("" = the project's; tests)
var uploaded := -1               ## runs the server accepted after this one (-1 = not tried yet)
var runner: DmBenchmark
var report := ""
var saved_path := ""
var _progress: Label
var _banner: PanelContainer      ## big centred notice over the frozen picture while the render breakdown runs
var _banner_step: Label
var _running := true


func _ready() -> void:
	theme = DmUi.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # clicks never reach the fight's HUD (main puts this screen on a layer above it)
	process_mode = Node.PROCESS_MODE_ALWAYS    # Esc works while the render breakdown holds the fight paused
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", DmUi.box(Color(DmUi.PANEL, 0.85), DmUi.BORDER, 1, 3, Vector2(18, 8)))
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 12)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	_progress = DmFrontUi.lbl("Starting the benchmark...", "body", 18, DmUi.BONE_100)
	box.add_child(_progress)
	_banner = PanelContainer.new()
	_banner.add_theme_stylebox_override("panel", DmUi.box(Color(DmUi.PANEL, 0.92), DmUi.GOLD, 2, 4, Vector2(34, 22)))
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.visible = false
	add_child(_banner)
	var bv := VBoxContainer.new()
	bv.add_theme_constant_override("separation", 8)
	_banner.add_child(bv)
	var big := DmFrontUi.lbl("FIGHT FROZEN ON PURPOSE", "display", 34, DmUi.GOLD, 3.0)
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(big)
	var why := DmFrontUi.lbl("The benchmark is measuring what each part of the picture costs. The game has not hung.", "body", 17, DmUi.BONE_100)
	why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(why)
	_banner_step = DmFrontUi.lbl("", "body", 17, DmUi.SPELL_300)
	_banner_step.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(_banner_step)
	_run.call_deferred()


func _run() -> void:
	runner = DmBenchmark.new()
	runner.configure(setup)
	if warm_s > 0.0:
		runner.warm_s = warm_s
	if measure_s > 0.0:
		runner.measure_s = measure_s
	runner.baked_dir = baked_dir
	runner.progress.connect(func(t: String) -> void: _progress.text = t + "   (Esc cancels)")
	runner.breakdown_step.connect(func(step: int, total: int, what: String) -> void:
		_banner.visible = true
		var n := clampi(step, 0, total + 1)
		_banner_step.text = "Step %d of %d: %s   (about %d s left, Esc cancels)" % [n + 1, total + 2, what, int((total + 1 - n) * (DmBenchmark.BREAK_SETTLE_S + DmBenchmark.BREAK_MEASURE_S))])
	add_child(runner)
	var r := await runner.run()
	runner.queue_free()
	runner = null
	_running = false
	if (r["phases"] as Array).is_empty():
		if quit_on_close:
			get_tree().quit()   # cancelled before any phase finished: nothing to show
		else:
			closed.emit()
		return
	report = DmBenchmark.format_text(r)
	DmBenchmark.log_text(report)
	saved_path = DmBenchmark.save_text(report)
	print("BENCHMARK saved to ", ProjectSettings.globalize_path(saved_path) if saved_path != "" else "(could not save)")
	var entry := DmBenchHistory.payload(r, report)
	var prev := DmBenchHistory.previous(entry)
	DmBenchHistory.record(entry)
	_show_results(r, prev)
	await _upload()
	if quit_on_close and DisplayServer.get_name() == "headless":
		get_tree().quit()   # nobody can press Quit: a scripted run ends with its report


func _upload() -> void:
	if api == null:
		_upload_status("Saved here; it is added to the online benchmark history the next time you log in.")
		return
	_upload_status("Adding the run to the online benchmark history...")
	uploaded = await DmBenchHistory.flush(api)
	var left := DmBenchHistory.pending_count()
	_upload_status("Added to the online benchmark history." if left == 0 else "Could not reach the server: the run is kept and sent the next time you log in.")


func _upload_status(t: String) -> void:
	var l := get_node_or_null("%Upload") as Label
	if l != null:
		l.text = t


func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if _running:
			if runner != null:
				runner.cancel()
				_progress.text = "Cancelling..."
		elif not quit_on_close:
			_close()


func _close() -> void:
	if quit_on_close:
		get_tree().quit()
	else:
		closed.emit()


func _show_results(r: Dictionary, prev: Dictionary = {}) -> void:
	for c in get_children():
		c.queue_free()
	var bg := ColorRect.new()
	bg.color = DmUi.VOID_950
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	add_child(DmFrontUi.backdrop())
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", DmUi.box(DmUi.PANEL, DmUi.BORDER, 1, 3, Vector2(26, 22)))
	plate.custom_minimum_size.x = 760
	center.add_child(plate)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	plate.add_child(v)
	var m: Dictionary = r["meta"]
	var title := DmFrontUi.lbl("BENCHMARK RESULTS" + ("  (cancelled)" if r.get("cancelled", false) else ""), "display", 28, DmUi.BONE_300, 4.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var setup_l := DmFrontUi.lbl(m.get("setup", ""), "body", 15, DmUi.SPELL_300, 0.0, true)
	setup_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(setup_l)
	for t in ["Build %s   %s" % [m["build"], m["date"]], "%s   %s   %s" % [m["gpu"], m["renderer"], m["resolution"]],
			"%s (%d threads)   Preset %s   V-Sync %s" % [m["cpu"], m["cores"], m["preset"], m["vsync"]]]:
		var l := DmFrontUi.lbl(t, "body", 13, DmUi.TEXT_MUTED)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)
	var warn := DmBenchmark.capped_warning(r)
	if warn != "":
		v.add_child(DmFrontUi.lbl("⚠ " + warn, "body", 15, DmUi.GOLD, 0.0, true))
	var ph: Array = r["phases"]
	var cards := HBoxContainer.new()
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("separation", 40)
	for p in ph:
		var c := VBoxContainer.new()
		c.add_child(_centered(DmFrontUi.lbl(p["label"], "body", 14, DmUi.SPELL_300)))
		c.add_child(_centered(DmFrontUi.lbl("%.1f" % p["avg_fps"], "display", 60, DmUi.GOLD)))
		c.add_child(_centered(DmFrontUi.lbl("average fps", "body", 14, DmUi.TEXT_MUTED)))
		c.add_child(_centered(DmFrontUi.lbl("%.1f ms" % p["p95_ms"], "display", 40, DmUi.BONE_100)))
		c.add_child(_centered(DmFrontUi.lbl("95th percentile frame time", "body", 14, DmUi.TEXT_MUTED)))
		cards.add_child(c)
	v.add_child(cards)
	v.add_child(DmUi.hrule())
	var grid := GridContainer.new()
	var cmp := not prev.is_empty() and ph.size() == 1
	grid.columns = 1 + ph.size() + (1 if cmp else 0)
	grid.add_theme_constant_override("h_separation", 28)
	grid.add_theme_constant_override("v_separation", 2)
	v.add_child(grid)
	grid.add_child(DmFrontUi.lbl("", "body", 14, DmUi.TEXT_MUTED))
	for p in ph:
		grid.add_child(DmFrontUi.lbl(p["label"], "body", 14, DmUi.SPELL_300))
	if cmp:
		grid.add_child(DmFrontUi.lbl("vs last run (%s)" % String(prev.get("version", "?")), "body", 14, DmUi.SPELL_300))
	for row in DmBenchmark.ROWS:
		var name_l := DmFrontUi.lbl(row[1], "body", 15, DmUi.TEXT_MUTED)
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(name_l)
		for p in ph:
			grid.add_child(DmFrontUi.lbl(row[2] % p.get(row[0], 0), "body", 15, DmUi.BONE_100))
		if cmp:
			var f := DmBenchHistory.change(ph[0], prev, row[0])
			var good := DmBenchHistory.better(row[0], f)
			grid.add_child(DmFrontUi.lbl("" if is_nan(f) else "%+.0f%%" % (f * 100.0), "body", 15,
				DmUi.TEXT_FAINT if good == 0 else (DmUi.UP if good > 0 else DmUi.DOWN_SOFT)))
	var budget := DmBenchmark.budget_lines(r)
	if not budget.is_empty():
		v.add_child(DmUi.hrule())
		for i in budget.size():
			var miss := budget[i].contains("MISS")
			v.add_child(DmFrontUi.lbl(budget[i].strip_edges(), "body", 14 if i == 0 else 13, DmUi.SPELL_300 if i == 0 else (DmUi.DOWN_SOFT if miss else DmUi.BONE_100), 0.0, true))
	var bd: Dictionary = r.get("breakdown", {})
	if not bd.is_empty():
		v.add_child(DmUi.hrule())
		var b: Dictionary = bd["base"]
		v.add_child(DmFrontUi.lbl("What each part costs (fight paused; everything on: %.0f draw calls, render CPU %.2f ms, frame %.2f ms)" % [b["draws"], b["render_cpu_ms"], b["frame_ms"]],
			"body", 14, DmUi.SPELL_300, 0.0, true))
		var g2 := GridContainer.new()
		g2.columns = 5
		g2.add_theme_constant_override("h_separation", 28)
		g2.add_theme_constant_override("v_separation", 2)
		v.add_child(g2)
		for h in ["Without", "draw calls", "render CPU ms", "GPU ms", "frame ms"]:
			g2.add_child(DmFrontUi.lbl(h, "body", 14, DmUi.TEXT_MUTED))
		for row: Dictionary in bd["rows"]:
			g2.add_child(DmFrontUi.lbl(row["what"], "body", 15, DmUi.TEXT_MUTED))
			var shaky := DmBenchmark.breakdown_unsteady(row)
			for k in ["draws", "render_cpu_ms", "render_gpu_ms", "frame_ms"]:
				var txt := ("%.0f" if k == "draws" else "%.2f") % -float(row[k])
				g2.add_child(DmFrontUi.lbl(txt + ("?" if shaky and k != "draws" else ""), "body", 15, DmUi.TEXT_FAINT if shaky and k != "draws" else DmUi.BONE_100))
	if not cmp:
		v.add_child(DmFrontUi.lbl("No earlier run of this setup on this PC to compare with yet.", "body", 12, DmUi.TEXT_FAINT, 0.0, true))
	var up := DmFrontUi.lbl("", "body", 12, DmUi.TEXT_FAINT, 0.0, true)
	up.name = "Upload"
	up.unique_name_in_owner = true
	v.add_child(up)
	var where := DmFrontUi.lbl("Saved to %s" % ProjectSettings.globalize_path(saved_path) if saved_path != "" else "Could not save the report", "body", 12, DmUi.TEXT_FAINT, 0.0, true)
	v.add_child(where)
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 14)
	v.add_child(btns)
	var copy := Button.new()
	copy.text = "Copy to clipboard"
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(report)
		copy.text = "Copied")
	btns.add_child(copy)
	var back := Button.new()
	back.text = "Quit" if quit_on_close else "Back"
	back.pressed.connect(_close)
	btns.add_child(back)
	back.grab_focus()


func _centered(l: Label) -> Label:
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l
