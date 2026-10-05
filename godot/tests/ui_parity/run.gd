extends SceneTree
## UI parity wave: tooltips, clickable toasts, chat commands, bug report in Settings, art, login backdrop.
##   godot --headless --path godot --script res://tests/ui_parity/run.gd

var _fail := 0
var _pass := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func make() -> Array:
	DmUiConfig.dir = ""
	var game := DmMockGame.new()
	root.add_child(game)
	var ui := DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	return [game, ui]


func _click(c: Control) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	c._gui_input(e)


func _run() -> void:
	var pair := make()
	var game: DmMockGame = pair[0]
	var ui: DmGameUi = pair[1]
	await _frames(3)

	# --- 2. clicking a NEW cue toast opens its panel ---
	ui.cues.show_cb.call(DmGameUi.CUE_TEXT["menu.atlas"], "menu.atlas")   # (the queue shows one cue at a time; call the shower directly)
	await _frames(2)
	var cue_toast: DmToast = null
	for t in ui.hud.toasts.get_children():
		if t is DmToast and t.on_click.is_valid() and t.get_meta("text") == DmGameUi.CUE_TEXT["menu.atlas"]:
			cue_toast = t
	_check(cue_toast != null, "a cue with a panel makes a clickable toast")
	if cue_toast != null:
		_check(cue_toast.mouse_filter == Control.MOUSE_FILTER_STOP, "clickable toast takes the mouse")
		_click(cue_toast)
		await _frames(6)
		_check(ui.is_open("atlas"), "clicking the Atlas cue toast opens the Atlas")
		_check(not is_instance_valid(cue_toast) or not cue_toast.is_inside_tree(), "the toast goes after the click")
	ui.close_panels()
	ui.hud.toast("Plain", "good")
	var plain: DmToast = ui.hud.toasts.get_child(ui.hud.toasts.get_child_count() - 1)
	_check(not plain.on_click.is_valid() and plain.mouse_filter == Control.MOUSE_FILTER_IGNORE, "an ordinary toast is not clickable")

	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
