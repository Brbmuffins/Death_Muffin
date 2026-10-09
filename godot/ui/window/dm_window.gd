class_name DmWindow
extends PanelContainer
## The web's floating panel (`.cw-plate.cw-panel-float`): a FIXED header (title, aka, close X: never scroll) over a body
## that scrolls beneath it, with the "Back to top" button (archive/legacy-web:src/ui/panelBody.ts), draggable by its header, Esc to close.
##
## Usage:
##   var w := DmWindow.new(); w.title = "Settings"; w.panel_width = 540
##   parent.add_child(w); w.body.add_child(my_control)   # `body` is the scrolling VBox
##   w.open() / w.close()
## Geometry mirrors ui.css: width 540 (`wide` 680), top 20px, centred, max height viewport - 190 px, 22px side padding.

signal closed
signal opened

const BACK_TO_TOP_AFTER := 120.0   # px scrolled before the button appears (panelBody.ts)
const BACK_TO_TOP_HIDE_S := 2.0    # hides this long after scrolling stops
const PAD_X := 22

@export var title: String = "Window"
@export var aka: String = ""       # the muted "Bag · I" beside the title
@export var panel_width: int = 540
@export var max_height_margin: int = 190
@export var top_gap: int = 20          # panel top offset (web: top 20px; Reliquary 12px)
@export var pad_y: int = 20            # plate top/bottom padding (Reliquary 16px)
@export var draggable: bool = true

## Add your content here (a VBoxContainer inside the scrolling body).
var body: VBoxContainer
var head: Control
var scroll: ScrollContainer
## Region between the head and the body where TabbedWindow puts its tab strip.
var strip_slot: VBoxContainer

static var _stack: Array[DmWindow] = []

var _root_box: VBoxContainer
var _title_label: Label
var _aka_label: Label
var _close_btn: DmIconButton
var _content_margin: MarginContainer
var _scroll_area: Control
var _dock: Control
var _back_btn: Button
var _corners: Control
var _shown_btt := false
var _last_scroll_ms := 0
var _hovered_btt := false
var _btt_timer: Timer
var _dragging := false
var _drag_off := Vector2.ZERO
var _user_placed := false
var _fit_queued := false


func _init() -> void:
	theme_type_variation = "DmPlate"
	theme = DmUi.theme()
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# Side padding lives inside head/body so the scrollbar can sit on the plate edge (web: body margin 0 -22px).
	var sb := (DmUi.theme().get_stylebox("panel", "DmPlate").duplicate() as StyleBoxFlat)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 20
	sb.content_margin_bottom = 20
	add_theme_stylebox_override("panel", sb)
	_build()


func _build() -> void:
	_root_box = VBoxContainer.new()
	_root_box.add_theme_constant_override("separation", 0)
	add_child(_root_box)

	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_left", PAD_X)
	hm.add_theme_constant_override("margin_right", PAD_X)
	_root_box.add_child(hm)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 12)
	hm.add_child(hv)
	head = hv
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.gui_input.connect(_on_head_input)
	row.mouse_default_cursor_shape = Control.CURSOR_MOVE
	hv.add_child(row)
	var tbox := HBoxContainer.new()
	tbox.add_theme_constant_override("separation", 12)
	tbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tbox)
	_title_label = DmUi.label("", "DmTitle")
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tbox.add_child(_title_label)
	_aka_label = DmUi.label("", "DmAka")
	_aka_label.size_flags_vertical = Control.SIZE_SHRINK_END
	_aka_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tbox.add_child(_aka_label)
	_close_btn = DmIconButton.new()
	_close_btn.tooltip_text = "Close (Esc)"
	_close_btn.pressed.connect(close)
	row.add_child(_close_btn)
	hv.add_child(DmUi.hrule())   # .cw-panel-head border-bottom

	strip_slot = VBoxContainer.new()
	strip_slot.add_theme_constant_override("separation", 0)
	_root_box.add_child(strip_slot)

	_scroll_area = Control.new()
	_scroll_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_area.clip_contents = true
	_root_box.add_child(_scroll_area)
	scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll_area.add_child(scroll)
	_content_margin = MarginContainer.new()
	_content_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_margin.add_theme_constant_override("margin_left", PAD_X)
	_content_margin.add_theme_constant_override("margin_right", PAD_X)
	_content_margin.add_theme_constant_override("margin_top", 14)
	_content_margin.add_theme_constant_override("margin_bottom", 2)
	scroll.add_child(_content_margin)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_margin.add_child(body)

	# Back to top dock: sits over the bottom-right of the scroll area.
	_dock = Control.new()
	_dock.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll_area.add_child(_dock)
	_back_btn = Button.new()
	_back_btn.theme_type_variation = "DmBackTop"
	_back_btn.text = DmUi.upper("↑ Back to top")
	_back_btn.focus_mode = Control.FOCUS_NONE
	_back_btn.visible = false
	_back_btn.custom_minimum_size = Vector2(0, 32)
	_back_btn.pressed.connect(func() -> void: scroll.scroll_vertical = 0)
	_back_btn.mouse_entered.connect(func() -> void: _hovered_btt = true)
	_back_btn.mouse_exited.connect(func() -> void:
		_hovered_btt = false
		_last_scroll_ms = Time.get_ticks_msec())
	_dock.add_child(_back_btn)
	_dock.resized.connect(_place_btt)
	_back_btn.resized.connect(_place_btt)
	_btt_timer = Timer.new()
	_btt_timer.one_shot = true
	_btt_timer.timeout.connect(_btt_check)
	add_child(_btt_timer)
	scroll.get_v_scroll_bar().value_changed.connect(_on_scrolled)

	# Chipped carved corners (.cw-plate::before/::after), drawn above the plate fill.
	_corners = DmCorners.new()
	add_child(_corners)

	_content_margin.minimum_size_changed.connect(_queue_fit)
	_apply_labels()


func _ready() -> void:
	get_viewport().size_changed.connect(_queue_fit)
	var sb := get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.content_margin_top = pad_y
		sb.content_margin_bottom = pad_y
	_apply_labels()
	custom_minimum_size.x = panel_width
	_queue_fit()


func _apply_labels() -> void:
	if _title_label == null:
		return
	_title_label.text = DmUi.upper(title)
	_aka_label.text = DmUi.upper(aka)   # .aka inherits the title's text-transform
	_aka_label.visible = aka != ""


func set_title(t: String, a: String = "") -> void:
	title = t
	aka = a
	_apply_labels()


# --- sizing / placement ------------------------------------------------------------------------------------
func _queue_fit() -> void:
	if _fit_queued:
		return
	_fit_queued = true
	_fit.call_deferred()


func _fit() -> void:
	_fit_queued = false
	if not is_inside_tree():
		return
	custom_minimum_size.x = panel_width
	var vp := get_viewport_rect().size
	var max_h := maxf(220.0, vp.y - max_height_margin)
	var content_h := _content_margin.get_combined_minimum_size().y
	var chrome: float = (head.get_parent() as Control).get_combined_minimum_size().y + strip_slot.get_combined_minimum_size().y + pad_y * 2.0  # plate top+bottom padding
	var avail := maxf(80.0, max_h - chrome)
	scroll.custom_minimum_size.y = minf(content_h, avail)
	_scroll_area.custom_minimum_size.y = minf(content_h, avail)
	size.y = 0   # shrink back to content
	if not _user_placed and visible:
		_place.call_deferred()


func _place() -> void:
	if not is_inside_tree():
		return
	var vp := get_parent_area_size()
	position = Vector2(roundf((vp.x - size.x) * 0.5), top_gap)


func _clamp_to_viewport() -> void:
	var vp := get_parent_area_size()
	position.x = clampf(position.x, -size.x + 120.0, vp.x - 120.0)
	position.y = clampf(position.y, 0.0, vp.y - 48.0)


# --- open / close -------------------------------------------------------------------------------------------
func open() -> void:
	if visible:
		return
	visible = true
	_stack.append(self)
	scroll.scroll_vertical = 0
	_queue_fit()
	await get_tree().process_frame
	_fit()
	_place()
	opened.emit()


func close() -> void:
	if not visible:
		return
	visible = false
	_stack.erase(self)
	_set_btt(false)
	closed.emit()


func _exit_tree() -> void:
	_stack.erase(self)


func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel") and _stack.size() > 0 and _stack.back() == self:
		close()
		get_viewport().set_input_as_handled()


# --- drag by header -----------------------------------------------------------------------------------------
func _on_head_input(event: InputEvent) -> void:
	if not draggable:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_drag_off = get_global_mouse_position() - global_position
		if event.pressed:
			move_to_front()
	elif event is InputEventMouseMotion and _dragging:
		_user_placed = true
		global_position = get_global_mouse_position() - _drag_off
		_clamp_to_viewport()


# --- Back to top --------------------------------------------------------------------------------------------
func _on_scrolled(v: float) -> void:
	if v <= BACK_TO_TOP_AFTER:
		if _shown_btt:
			_set_btt(false)
		return
	_last_scroll_ms = Time.get_ticks_msec()
	if not _shown_btt:
		_set_btt(true)
	if _btt_timer.is_stopped():
		_btt_timer.start(BACK_TO_TOP_HIDE_S)


func _btt_check() -> void:
	if not _shown_btt:
		return
	var left := BACK_TO_TOP_HIDE_S - (Time.get_ticks_msec() - _last_scroll_ms) / 1000.0
	if _hovered_btt:
		_btt_timer.start(BACK_TO_TOP_HIDE_S)
	elif left > 0.0:
		_btt_timer.start(left)
	else:
		_set_btt(false)


func _set_btt(on: bool) -> void:
	_shown_btt = on
	_back_btn.visible = on
	if on:
		_place_btt()


func _place_btt() -> void:
	# bottom-right of the scroll area: right 22px, bottom 12px (.cw-back-top button)
	_back_btn.position = _dock.size - _back_btn.size - Vector2(PAD_X, 12)


func back_to_top_visible() -> bool:
	return _shown_btt
