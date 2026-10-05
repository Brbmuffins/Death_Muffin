class_name DmTip
extends CanvasLayer
## The web's custom hover cards, outside Godot's native tooltip (which waits half a second and can't follow the cursor):
##  - FOLLOW  (`.cw-tooltip`, InventoryPanel.showTooltip/moveTooltip): shown on pointerenter with no delay, `left = min(x + 14, W - w - 8)`,
##    `top = min(y + 14, H - h - 8)`, follows the pointer, never takes the mouse.
##  - ANCHOR  (`.hud-spell-tooltip`, HUD.positionTooltip): centred above the anchor (8 px gap, 12 px margin, below when there is no room), takes the
##    mouse so its long text can be scrolled, hides 180 ms after the pointer leaves both the anchor and the card, Esc closes it.
## One layer for the whole game (`DmTip.of(node)`); owners call show_follow / show_anchor on mouse_entered and hide_for on mouse_exited.

enum Mode { NONE, FOLLOW, ANCHOR }

const LAYER := 128
const FOLLOW_OFFSET := 14.0
const EDGE := 8.0
const MARGIN := 12.0
const HIDE_DELAY := 0.18

var mode := Mode.NONE
var owner_ctl: Control = null
var content: Control = null
var anchor_ctl: Control = null
var test_mouse: Variant = null   ## tests: a fixed pointer position (headless runs have no pointer)
var _hide_in := -1.0
var _age := 0
var _old: Control = null


static func of(node: Node) -> DmTip:
	var root := node.get_tree().root
	var t := root.get_node_or_null("DmTipLayer") as DmTip
	if t == null:
		t = DmTip.new()
		t.name = "DmTipLayer"
		root.add_child(t)
	return t


func _init() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


## An item card that follows the pointer.
func show_follow(owner_: Control, card: Control) -> void:
	_begin(owner_, card, Mode.FOLLOW)
	_place()


## A card centred above `owner_` (the web's spell card).
func show_anchor(owner_: Control, card: Control) -> void:
	_begin(owner_, card, Mode.ANCHOR)
	_place()


## Replace the card of the current owner (live refresh). The old card stays up until the new one has settled, so it never blinks.
func replace_content(card: Control) -> void:
	if content == null:
		return
	if _old != null:
		remove_child(_old)
		_old.queue_free()
	_old = content
	content = card
	_age = 0
	add_child(content)
	if mode == Mode.FOLLOW:
		_ignore_mouse(content)


func is_showing_for(owner_: Control) -> bool:
	return mode != Mode.NONE and owner_ctl == owner_


func hide_for(owner_: Control) -> void:
	if owner_ctl == owner_ and mode != Mode.NONE:
		if mode == Mode.ANCHOR:
			_hide_in = HIDE_DELAY   # a small bridge lets the pointer cross the gap into a scrollable card
		else:
			hide_now()


func hide_now() -> void:
	if _old != null:
		remove_child(_old)
		_old.queue_free()
		_old = null
	mode = Mode.NONE
	_hide_in = -1.0
	if content != null:
		remove_child(content)
		content.queue_free()
		content = null
	owner_ctl = null
	set_process(false)


func _begin(owner_: Control, card: Control, m: Mode) -> void:
	if _old != null:
		remove_child(_old)
		_old.queue_free()
		_old = null
	if content != null:
		remove_child(content)
		content.queue_free()
	owner_ctl = owner_
	content = card
	mode = m
	_hide_in = -1.0
	_age = 0
	add_child(content)
	content.top_level = false
	if m == Mode.FOLLOW:
		_ignore_mouse(content)
	set_process(true)


static func _ignore_mouse(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for ch in c.get_children():
		if ch is Control:
			_ignore_mouse(ch)


func _process(delta: float) -> void:
	if mode == Mode.NONE:
		set_process(false)
		return
	if not is_instance_valid(owner_ctl) or not owner_ctl.is_visible_in_tree() or not is_instance_valid(content):
		hide_now()
		return
	if owner_ctl.get_viewport().gui_is_dragging():
		hide_now()
		return
	var mp := _mouse()
	if mode == Mode.FOLLOW:
		if not owner_ctl.get_global_rect().has_point(mp):
			hide_now()
			return
		_place()
	else:
		var over_owner := owner_ctl.get_global_rect().has_point(mp)
		var over_card := content.get_global_rect().has_point(mp)
		if over_owner or over_card:
			_hide_in = -1.0
		elif _hide_in < 0.0:
			_hide_in = HIDE_DELAY
		if _hide_in >= 0.0:
			_hide_in -= delta
			if _hide_in <= 0.0:
				hide_now()
				return
		_place()   # every frame: wrapped text settles over a few frames and a live card may change height


func _mouse() -> Vector2:
	if test_mouse != null:
		return test_mouse
	return get_viewport().get_mouse_position()


func _input(event: InputEvent) -> void:
	if mode == Mode.ANCHOR and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		hide_now()
		get_viewport().set_input_as_handled()


func _place() -> void:
	if content == null:
		return
	var vp := content.get_viewport_rect().size
	var sz := content.get_combined_minimum_size()
	content.size = sz
	var pos := Vector2.ZERO
	if mode == Mode.FOLLOW:
		var mp := _mouse()
		pos = Vector2(minf(mp.x + FOLLOW_OFFSET, vp.x - sz.x - EDGE), minf(mp.y + FOLLOW_OFFSET, vp.y - sz.y - EDGE))
	elif is_instance_valid(owner_ctl):
		var a := owner_ctl.get_global_rect()
		var left := maxf(MARGIN, minf(vp.x - sz.x - MARGIN, a.position.x + a.size.x * 0.5 - sz.x * 0.5))
		var above := a.position.y - sz.y - 8.0
		var top := maxf(MARGIN, minf(vp.y - sz.y - MARGIN, above if above >= MARGIN else a.end.y + 8.0))
		pos = Vector2(left, top)
	content.position = pos
	# wrapped labels need two layout passes before the card's height is real: stay invisible until then
	content.modulate.a = 1.0 if _age >= 2 else 0.0
	if _age >= 2 and _old != null:
		remove_child(_old)
		_old.queue_free()
		_old = null
	_age += 1
