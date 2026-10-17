class_name DmTipCard
extends PanelContainer
## The first-time "Covenant counsel" card (Onboarding.ts `.cw-tip`): kicker row ("⋮⋮ Covenant counsel" + "Move this card"),
## uppercase title, body (web `<kbd>` / `<b>` markup -> BBCode), foot ("Click to dismiss" + "Don't show tips"), draining timer line.
## Draggable by the kicker row, click anywhere else dismisses. 360 px wide, top-left under the hero frame in the web.

signal dismissed
signal skip_tips

@export var show_ms: int = 8000

var _title: Label
var _body: RichTextLabel
var _timer_rect: Control
var _t := 0.0
var _running := false
var _dragging := false
var _drag_off := Vector2.ZERO


func _init() -> void:
	theme = DmUi.theme()
	theme_type_variation = "DmTipPlate"
	custom_minimum_size.x = 360
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	add_child(v)
	var k := HBoxContainer.new()
	k.mouse_default_cursor_shape = Control.CURSOR_DRAG
	k.mouse_filter = Control.MOUSE_FILTER_STOP
	k.gui_input.connect(_on_kicker_input)
	v.add_child(k)
	var kl := DmUi.label(DmUi.upper("⋮⋮ Covenant counsel"), "DmKicker")
	kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	k.add_child(kl)
	var mh := DmUi.label("Move this card", "DmFaint")
	mh.add_theme_font_size_override("font_size", 11)
	mh.add_theme_color_override("font_color", DmUi.TEXT_MUTED)
	mh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	k.add_child(mh)
	_title = DmUi.label("", "DmTipTitle")
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_title)
	_body = RichTextLabel.new()
	_body.theme_type_variation = "DmRichTip"
	_body.bbcode_enabled = true
	_body.fit_content = true
	_body.scroll_active = false
	_body.clip_contents = false   # fit_content: the box is the text
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_color_override("default_color", DmUi.BONE_300)
	v.add_child(_body)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	v.add_child(foot)
	var fl := DmUi.label("Click to dismiss", "DmFaint")
	fl.add_theme_font_size_override("font_size", 12)
	fl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot.add_child(fl)
	var skip := Button.new()
	skip.theme_type_variation = "DmLink"
	skip.text = "Don't show tips"
	skip.focus_mode = Control.FOCUS_NONE
	skip.pressed.connect(func() -> void: skip_tips.emit())
	foot.add_child(skip)
	add_child(DmCorners.new())
	# the draining timer line (.timer): an overlay so the PanelContainer layout leaves it alone
	_timer_rect = Control.new()
	_timer_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_rect.draw.connect(_draw_timer)
	add_child(_timer_rect)


func set_tip(kicker_title: String, body_markup: String, ms: int = 8000) -> void:
	_title.text = DmUi.upper(kicker_title)
	_body.text = DmUi.markup(body_markup)
	show_ms = ms
	_t = 0.0
	_running = ms > 0
	set_process(_running)
	show_timer()


func _process(delta: float) -> void:
	if not _running:
		return
	_t += delta * 1000.0
	show_timer()
	if _t >= show_ms:
		_running = false
		dismissed.emit()


static var _timer_cols := PackedColorArray()   ## the line's 24 steps, veil to spell: the same colours at every draw
var _line := RID()      ## the draining line's canvas item, a child of the control's own: drawn when the control gets its size, squeezed by its transform each frame
var _line_k := 1.0      ## what is left of the time, as the line shows it


## The draining line (.timer): drawn once, whole, in 24 steps, on an item of its own; what is left of the time squeezes that item (the steps shrink with it, as they did when every
## frame drew the line again), so a frame sets one transform where it drew 24 rectangles.
func show_timer() -> void:
	_line_k = maxf(clampf(1.0 - _t / maxf(1.0, float(show_ms)), 0.0, 1.0), 0.0001)
	if _line.is_valid():
		RenderingServer.canvas_item_set_transform(_line, Transform2D(Vector2(_line_k, 0.0), Vector2(0.0, 1.0), Vector2.ZERO))


func _draw_timer() -> void:
	if not _line.is_valid():
		_line = RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(_line, _timer_rect.get_canvas_item())
	if _timer_cols.is_empty():
		_timer_cols.resize(24)
		for i in 24:
			_timer_cols[i] = DmUi.VEIL_500.lerp(DmUi.SPELL_300, i / 23.0)
	RenderingServer.canvas_item_clear(_line)
	var w := _timer_rect.size.x
	var y := _timer_rect.size.y - 2.0
	for i in 24:
		var x0 := w * i / 24.0
		RenderingServer.canvas_item_add_rect(_line, Rect2(x0, y, w * (i + 1) / 24.0 - x0 + 0.5, 2.0), _timer_cols[i])
	show_timer()


func _exit_tree() -> void:
	if _line.is_valid():
		RenderingServer.free_rid(_line)
		_line = RID()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not _dragging:
		dismissed.emit()


func _on_kicker_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_drag_off = get_global_mouse_position() - global_position
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		global_position = get_global_mouse_position() - _drag_off
