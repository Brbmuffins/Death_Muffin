class_name DmCounselView
extends Control
## Draws the Covenant counsel for a DmCounsel: the movable DmTipCard (Onboarding.ts present/place) and the TIP_ANCHOR glow over the HUD part
## the card is about (.dm-tip-glow: 2 px #e2c98f outline at 3 px offset, pulsing halo over 1.4 s). Add it as a full-screen child of the HUD layer.
##   view.setup(counsel, hud, store)      # hud: DmHud (tip_anchor_rect / tip_default_position); store: DmCounselStore for the dragged position
## Card visibility follows ui.css: while the area banner shows only urgent/danger cards stay; while a panel is open only urgent/asked cards stay.

const GLOW := Color("e2c98f")
const POSITION_KEY := "dm_counsel_position_v1"

var reduce_motion := false

var _counsel: DmCounsel
var _hud: Node
var _store: DmCounselStore
var _card: DmTipCard
var _fading: Array[DmTipCard] = []
var _kind := ""
var _glow_id := ""
var _glow := _GlowLayer.new()
var _t := 0.0
var _position: Variant = null
var _last_pos := Vector2.ZERO
var _dragging := false
var _placed := false
var _hover := false


class _GlowLayer extends Control:
	var rect := Rect2()
	var phase := 0.0
	var animate := true

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _draw() -> void:
		if rect.size.x <= 0.0:
			return
		var k := (0.5 - 0.5 * cos(phase * TAU / 1.4)) if animate else 0.0
		var r := Rect2(rect.position - global_position, rect.size).grow(3.0)
		# halo: box-shadow 0 0 18px rgba(gold, .55) at the glow's midpoint
		if k > 0.0:
			for i in 9:
				var g := 2.0 + i * 2.0
				draw_rect(r.grow(g), Color(GLOW, 0.55 * k * (1.0 - i / 9.0) * 0.16), false, 2.0)
		draw_rect(r, Color(GLOW, lerpf(1.0, 0.35, k)), false, 2.0)


func setup(counsel: DmCounsel, hud: Node, store: DmCounselStore = null) -> void:
	_counsel = counsel
	_hud = hud
	_store = store if store != null else DmCounselStore.new()
	var raw := _store.get_item(POSITION_KEY)
	if raw != "":
		var p: Variant = JSON.parse_string(raw)
		if p is Dictionary and p.has("x") and p.has("y"):
			_position = Vector2(float(p["x"]), float(p["y"]))
	counsel.card_shown.connect(_on_card_shown)
	counsel.card_hidden.connect(_on_card_hidden)
	counsel.card_removed.connect(_on_card_removed)
	counsel.glow_changed.connect(func(id: String) -> void: _glow_id = id)


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_glow)


func card() -> DmTipCard:
	return _card


## Screen rect of what the card is lighting (Rect2() when nothing is lit or the HUD part is hidden).
func glow_rect() -> Rect2:
	return _glow.rect


func _on_card_shown(id: String, kind: String, title_html: String, body_html: String, ms: int) -> void:
	if _card != null:
		_card.queue_free()
	_kind = kind
	_card = DmTipCard.new()
	add_child(_card)
	_card.set_tip(title_html, body_html, ms)
	_card.set_process(false)   # the counsel's clock owns the timer; _process below mirrors it onto the draining line
	_card.dismissed.connect(func() -> void: _counsel.dismiss())
	_card.skip_tips.connect(func() -> void: _counsel.skip())
	_card.mouse_entered.connect(func() -> void:
		_hover = true
		_counsel.pause_card())
	_card.mouse_exited.connect(func() -> void:
		_hover = false
		_counsel.resume_card(_dragging))
	_card.modulate.a = 0.0
	_placed = false
	_dragging = false
	_hover = false
	_place_after_layout()


func _on_card_hidden(_id: String) -> void:
	if _card != null:
		_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fading.append(_card)
		_card = null


func _on_card_removed() -> void:
	for c in _fading:
		if is_instance_valid(c):
			c.queue_free()
	_fading.clear()


func _place_after_layout() -> void:
	var c := _card
	await get_tree().process_frame
	await get_tree().process_frame
	if c == _card:
		_place()


## Onboarding.place: default corner (under the party list in co-op) or where the player dragged it, kept 8 px inside the screen.
func _place(pos: Variant = null) -> void:
	if _card == null:
		return
	_card.reset_size()
	var size := _card.size
	var vp := get_viewport_rect().size
	var base: Vector2 = _hud.tip_default_position() if _hud != null and _hud.has_method("tip_default_position") else Vector2(18, 70)
	var p: Vector2 = pos if pos != null else (_position if _position != null else base)
	var c := Vector2(maxf(8.0, minf(p.x, vp.x - size.x - 8.0)), maxf(8.0, minf(p.y, vp.y - size.y - 8.0)))
	_card.position = c
	_last_pos = c
	_placed = true


func _save_position() -> void:
	if _card == null:
		return
	_position = _card.position
	_store.set_item(POSITION_KEY, JSON.stringify({"x": _card.position.x, "y": _card.position.y}))


func _process(delta: float) -> void:
	_t += delta
	# glow
	var rect := Rect2()
	if _glow_id != "" and _hud != null:
		var key := DmCounselData.hud_anchor_key(_glow_id)
		if key != "":
			rect = _hud.tip_anchor_rect(key)
	_glow.animate = not reduce_motion
	_glow.phase = _t
	if rect != _glow.rect or rect.size.x > 0.0:
		_glow.rect = rect
		_glow.queue_redraw()
	# the card
	for c in _fading:
		if is_instance_valid(c):
			c.modulate.a = maxf(0.0, c.modulate.a - delta / 0.2)
			c.position.y += delta * 30.0
	if _card == null or _counsel == null:
		return
	if not _placed:
		return
	# the timer line mirrors the counsel's clock (pausing on hover/drag)
	_card._t = _counsel.card_elapsed_ms()
	_card._timer_rect.queue_redraw()
	# dragging (the kit card moves itself): pause while the pointer holds it, remember where it was dropped
	if _placed:
		if not _dragging and _card.position != _last_pos and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_dragging = true
			_counsel.pause_card()
		elif _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_dragging = false
			_place(_card.position)
			_save_position()
			if not _hover:
				_counsel.resume_card()
		_last_pos = _card.position
	# ui.css: banner / open panel hide the cards that are not about them
	var b := _counsel.busy_state()
	var hide_it := false
	if not _dragging:
		if b["banner"] and _kind != "urgent" and _kind != "danger":
			hide_it = true
		if b["panel"] and _kind != "urgent" and _kind != "asked":
			hide_it = true
	_card.modulate.a = move_toward(_card.modulate.a, 0.0 if hide_it else 1.0, delta / 0.2)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE if hide_it else Control.MOUSE_FILTER_STOP
