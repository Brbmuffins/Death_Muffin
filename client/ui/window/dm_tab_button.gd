class_name DmTabButton
extends Button
## A tab (.cw-tabwin-tab): toggle button, optional key cap on the right, optional gold NEW pip on the corner.

var _key := ""
var _overlay: Control
var _pip: Control
var _cap_w := 0.0


func _init() -> void:
	theme_type_variation = "DmTab"
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(0, 36)


func setup(label: String, key: String = "") -> void:
	text = DmUi.upper(label)
	_key = key
	if key != "":
		var f := DmUi.font("numeric")
		_cap_w = f.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 12.0
		text = text + "".lpad(0) + " ".repeat(int(ceil((_cap_w + 4.0) / 4.0)))


func _ready() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_extras)
	add_child(_overlay)
	_pip = DmUi.new_pip()
	_pip.visible = false
	_overlay.add_child(_pip)
	toggled.connect(func(_on: bool) -> void: _overlay.queue_redraw())


func set_new(on: bool) -> void:
	_pip.visible = on
	_pip.position = Vector2(size.x - 18.0, -7.0)


func _draw_extras() -> void:
	if _key == "":
		return
	var f := DmUi.font("numeric")
	var cap := Rect2(size.x - 14.0 - _cap_w, size.y * 0.5 - 8.0, _cap_w, 16.0)
	_overlay.draw_rect(Rect2(cap.position, cap.size), Color(DmUi.VOID_950, 0.55))
	_overlay.draw_rect(Rect2(cap.position, cap.size), DmUi.BORDER_STRONG, false, 1.0)
	_overlay.draw_string(f, cap.position + Vector2(0, 12.0), _key, HORIZONTAL_ALIGNMENT_CENTER, cap.size.x, 12, DmUi.BONE_100)
