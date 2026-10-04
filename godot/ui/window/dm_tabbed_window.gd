class_name DmTabbedWindow
extends DmWindow
## TabbedWindow.ts: one window hosting several panels as tabs. The tab strip is fixed under the header (it never scrolls);
## only the active tab's content shows in the scrolling body. Tab = Cormorant 14px uppercase, optional key cap, optional NEW pip.

signal tab_changed(id: String)

var _tabs: Dictionary = {}   # id -> {btn, content, pip}
var _order: Array[String] = []
var active: String = ""
var _strip: HFlowContainer
var _group := ButtonGroup.new()


func _init() -> void:
	super._init()
	panel_width = 860
	_strip = HFlowContainer.new()
	_strip.add_theme_constant_override("h_separation", 6)
	_strip.add_theme_constant_override("v_separation", 6)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", PAD_X)
	m.add_theme_constant_override("margin_right", PAD_X)
	m.add_theme_constant_override("margin_top", 10)
	m.add_child(_strip)
	strip_slot.add_child(m)


## `content` is hidden until its tab is active. Returns the tab button.
func add_tab(id: String, label: String, content: Control, key: String = "") -> Button:
	var b := DmTabButton.new()
	b.setup(label, key)
	b.button_group = _group
	b.pressed.connect(func() -> void: select_tab(id))
	_strip.add_child(b)
	content.visible = false
	body.add_child(content)
	_tabs[id] = {"btn": b, "content": content}
	_order.append(id)
	if active == "":
		select_tab(id)
	return b


func select_tab(id: String) -> void:
	if not _tabs.has(id):
		return
	if active != "" and _tabs.has(active):
		_tabs[active]["content"].visible = false
		# set_pressed_no_signal bypasses the ButtonGroup, so release the old tab by hand.
		(_tabs[active]["btn"] as Button).set_pressed_no_signal(false)
	active = id
	_tabs[id]["content"].visible = true
	(_tabs[id]["btn"] as Button).set_pressed_no_signal(true)
	scroll.scroll_vertical = 0
	tab_changed.emit(id)


func set_tab_hidden(id: String, hidden: bool) -> void:
	if _tabs.has(id):
		(_tabs[id]["btn"] as Button).visible = not hidden


func set_new(id: String, on: bool) -> void:
	if _tabs.has(id):
		(_tabs[id]["btn"] as DmTabButton).set_new(on)
