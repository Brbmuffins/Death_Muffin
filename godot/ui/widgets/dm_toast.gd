class_name DmToast
extends PanelContainer
## `.hud-toast`: a short message strip. kind: "" | "good" | "err" | "loot" | "loot_major" | "new_cue".
## Fades in 0.25 s, holds `hold_s`, fades out 0.5 s, then frees itself. Stack several in a VBoxContainer centred under the HUD top.

var hold_s: float = 8.0
var kind: String = ""
var on_click: Callable = Callable()   ## `.hud-toast.clickable`: a button (a NEW cue opens its panel); clicking runs it and removes the toast
var _label: Label
var _hover := false


static func make(text: String, kind_: String = "", hold: float = 8.0) -> DmToast:
	var t := DmToast.new()
	t.kind = kind_
	t.hold_s = hold
	t._build(text)
	return t


func _build(text: String) -> void:
	theme = DmUi.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	match kind:
		"good": theme_type_variation = "DmToastGood"
		"err": theme_type_variation = "DmToastErr"
		"loot_major", "new_cue": theme_type_variation = "DmToastMajor"
		_: theme_type_variation = "DmToast"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	add_child(row)
	if kind == "new_cue":
		row.add_child(DmUi.new_pip("NEW"))
	_label = DmUi.label(text, "DmToastText")
	# single line unless wider than the web's max (480 px), then wrap at that width
	var fw := DmUi.font("body").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	if fw > 470.0:
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_label.custom_minimum_size.x = 470.0
	if kind == "loot":
		_label.add_theme_font_size_override("font_size", 13)
		_label.add_theme_color_override("font_color", DmUi.BONE_300)
	elif kind == "loot_major":
		_label.add_theme_color_override("font_color", Color("f1e2b8"))
	row.add_child(_label)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	modulate.a = 0.0


## Makes the toast a button like the web's `onClick` toast: pointer cursor, dotted gold underline, gold border on hover, Enter/Space.
func set_clickable(cb: Callable) -> void:
	on_click = cb
	if not cb.is_valid():
		return
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func() -> void: _set_hover(true))
	mouse_exited.connect(func() -> void: _set_hover(false))
	queue_redraw()


func _set_hover(on: bool) -> void:
	_hover = on
	if on:
		var sb := get_theme_stylebox("panel").duplicate() as StyleBoxFlat
		if sb != null:
			sb.border_color = Color("e2c98f")
			add_theme_stylebox_override("panel", sb)
	else:
		remove_theme_stylebox_override("panel")


func activate() -> void:
	if not on_click.is_valid():
		return
	var cb := on_click
	on_click = Callable()
	cb.call()
	if is_inside_tree():
		get_parent().remove_child(self)
	queue_free()


func _gui_input(event: InputEvent) -> void:
	if not on_click.is_valid():
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		activate()
	elif event is InputEventKey and event.pressed and (event.keycode == KEY_ENTER or event.keycode == KEY_SPACE):
		accept_event()
		activate()


func _draw() -> void:
	if not on_click.is_valid() or _label == null:
		return
	# text-decoration: underline dotted rgba(226,201,143,.6) under the text line
	var r := _label.get_global_rect()
	var y := r.position.y - global_position.y + minf(r.size.y, 22.0) - 3.0
	var x0 := r.position.x - global_position.x
	var col := Color(0.886, 0.788, 0.561, 0.6)
	var x := x0
	while x < x0 + minf(r.size.x, _label.get_minimum_size().x):
		draw_rect(Rect2(x, y, 1.5, 1.0), col)
		x += 3.0


func _ready() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.25)
	tw.tween_interval(hold_s)
	tw.tween_property(self, "modulate:a", 0.0, 0.5)
	tw.tween_callback(queue_free)
