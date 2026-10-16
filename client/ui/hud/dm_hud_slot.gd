class_name DmHudSlot
extends VBoxContainer
## One action-bar slot (`.hud-slot`): 62 px icon button with a clockwise cooldown sweep, cooldown seconds, essence cost,
## optional rune badge, plus the key cap under it ("1".."4", "RMB", "R", "LMB"). States: nores (dimmed), empowered (jade pulse),
## locked (grayscale + unlock level), alt (right-click action: ember accent + left rule).
## Driven by `apply(slot_dict)`; see ui/hud/README.md ("slots").
## Ported (client/code.list): the icon and its greyed variants come from the HUD atlas (no shader material, so a dimmed slot costs no extra draw), the cooldown
## sweep is a handful of triangles in one mesh (it was a polygon per 2 % of the sweep, up to 50 draw calls), and the border rectangles come from the atlas too,
## on the layers of DmHudKit: icon, then the sweep, then the borders over it, then the text.

signal pressed          ## left click on the icon (web: click-to-cast)
signal swap_pressed     ## left click on the key cap while `swap` is on
signal hover_changed(on: bool)   ## pointer entered / left the 62 px icon (the web's pointerenter / pointerleave -> spell card)

const BTN := 62.0
const EMBER := Color("d0612e")
const JADE := Color("6fe3c8")

var left_ms: float = 0.0
var total_ms: float = 1.0
var affordable: bool = true
var empowered: bool = false
var locked: bool = false
var needs: String = ""      ## "" or what the rite needs and the world lacks right now ("corpse" / "legion"): dimmed + a small note, not a lock
var alt: bool = false
var unlock_level: int = 10
var cost: int = 0
var key_text: String = ""
var swap: bool = false
var icon_path: String = ""
var rune_path: String = ""

var button: Control          ## the 62 px icon holder: the spell card's anchor
var _icon: TextureRect
var _art: Control    ## the cooldown sweep (Z_ART)
var _edge: Control   ## the borders, over the sweep (Z_EDGE)
var _sweep := DmHudMesh.new()
var _cdtext: Label
var _cost: Label
var _lock: Label
var _need: Label
var _key_panel: PanelContainer
var _key: Label
var _swap_ico: Label
var _rune: TextureRect
var _flash: float = 0.0
var _t: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 5)
	alignment = BoxContainer.ALIGNMENT_BEGIN
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(BTN, BTN)
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# no clip_contents: everything inside is laid out within the 62 px square, and a clip is a scissor state change per slot
	holder.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	holder.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit())
	holder.mouse_entered.connect(func() -> void: hover_changed.emit(true))
	holder.mouse_exited.connect(func() -> void: hover_changed.emit(false))
	button = holder
	add_child(holder)
	_icon = TextureRect.new()
	_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.z_index = DmHudKit.Z_CHROME
	holder.add_child(_icon)
	_art = Control.new()
	_art.set_anchors_preset(Control.PRESET_FULL_RECT)
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.z_index = DmHudKit.Z_ART
	_art.draw.connect(_draw_art)
	holder.add_child(_art)
	_edge = Control.new()
	_edge.set_anchors_preset(Control.PRESET_FULL_RECT)
	_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edge.z_index = DmHudKit.Z_EDGE
	_edge.draw.connect(_draw_edge)
	holder.add_child(_edge)
	_cdtext = DmHudKit.lbl("", 17, DmUi.BONE_100, "numeric")
	_cdtext.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cdtext.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cdtext.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	holder.add_child(_cdtext)
	_cost = DmHudKit.lbl("", 11, Color("cbb8ff"), "numeric")
	_cost.position = Vector2(BTN - 3 - 14, 2)
	_cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cost.custom_minimum_size = Vector2(14, 0)
	_cost.size = Vector2(14, 14)
	_cost.anchor_left = 1.0
	_cost.anchor_right = 1.0
	_cost.offset_left = -28
	_cost.offset_right = -3
	_cost.offset_top = 0
	holder.add_child(_cost)
	_lock = DmHudKit.lbl("", 11, DmUi.BONE_300, "numeric")
	_lock.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_lock.offset_top = -17
	_lock.offset_bottom = -2
	_lock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	holder.add_child(_lock)
	_need = DmHudKit.lbl("", 10, Color("f0b08a"), "numeric")
	_need.set_anchors_preset(Control.PRESET_FULL_RECT)
	_need.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_need.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_need.add_theme_constant_override("outline_size", 3)
	_need.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	holder.add_child(_need)
	_rune = TextureRect.new()
	_rune.position = Vector2(2, BTN - 2 - 19)
	_rune.size = Vector2(19, 19)
	_rune.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rune.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_rune.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rune.z_index = DmHudKit.Z_CHROME
	_rune.visible = false
	holder.add_child(_rune)
	# key cap: min 20 wide, padding 0 5, 18 line + 1px border, numeric 12
	_key_panel = DmHudKit.panel(DmUi.INSET, DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(5, 0, 5, 0))
	_key_panel.custom_minimum_size = Vector2(20, 20)
	_key_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_key_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_key_panel.gui_input.connect(func(e: InputEvent) -> void:
		if swap and e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			swap_pressed.emit())
	var kh := HBoxContainer.new()
	kh.add_theme_constant_override("separation", 4)
	kh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_key_panel.add_child(kh)
	_key = DmHudKit.lbl("", 12, DmUi.BONE_300, "numeric", false)
	_key.custom_minimum_size.y = 18
	_key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	kh.add_child(_key)
	_swap_ico = DmHudKit.lbl("⇄", 10, DmUi.SPELL_300, "body", false)
	_swap_ico.modulate.a = 0.55
	_swap_ico.visible = false
	kh.add_child(_swap_ico)
	add_child(_key_panel)
	set_process(false)   # only while empowered or flashing (see _wake)


## Slot dictionary -> state. Keys: icon key cost left_ms total_ms affordable empowered locked unlock_level alt rune_icon swap.
var _kp_alt := -1   # the key panel's style is rebuilt only when alt flips
var _drawn_pct := -1     # the cooldown percent the sweep was last drawn for
var _drawn_look := -1    # the border look (alt, empowered) the edge was last drawn for
var _dim := -1      # the icon variant shown: 0 = normal, else a DmHudAtlas.DIM_* level

var _last: Dictionary = {}   ## the slot dict last applied (a copy: the view-model reuses its dictionaries)

func apply(s: Dictionary) -> void:
	if s == _last:
		return
	_last = s.duplicate()
	var new_icon: String = String(s.get("icon", ""))
	var icon_changed := new_icon != icon_path
	if icon_changed:
		icon_path = new_icon
	var new_rune: String = String(s.get("rune_icon", ""))
	if new_rune != rune_path:
		rune_path = new_rune
		_rune.texture = DmHudKit.tex(rune_path)
		_rune.visible = rune_path != ""
	left_ms = float(s.get("left_ms", 0.0))
	total_ms = maxf(float(s.get("total_ms", 1.0)), 1.0)
	affordable = bool(s.get("affordable", true))
	empowered = bool(s.get("empowered", false))
	locked = bool(s.get("locked", false))
	needs = String(s.get("needs", ""))
	unlock_level = int(s.get("unlock_level", 10))
	alt = bool(s.get("alt", false))
	swap = bool(s.get("swap", false))
	cost = int(s.get("cost", 0))
	key_text = String(s.get("key", ""))
	_cdtext.text = cd_text(left_ms)
	_cost.text = str(cost) if cost > 0 else ""
	DmHudKit.set_color(_cost, "font_color", Color("9ff5e0") if empowered else (Color("f0b08a") if alt else Color("cbb8ff")))
	_lock.text = str(unlock_level) if locked else ""
	_need.text = ("no " + needs) if needs != "" and not locked and left_ms <= 0.0 else ""
	_key.text = key_text
	DmHudKit.set_color(_key, "font_color", Color("f0b08a") if alt else DmUi.BONE_300)
	DmHudKit.set_font_size(_key, "font_size", 10 if alt else 12)
	_swap_ico.visible = swap
	_key_panel.tooltip_text = "Swap this rite (L)" if swap else ""
	_icon.get_parent().tooltip_text = ""   # no hover tooltip on the bar; spell info lives in the Grimoire
	# a rite out of essence, locked, or waiting for a corpse or a legion is the same art greyed and darker (the baked variants of the atlas)
	var dim := 0
	if locked:
		dim = DmHudAtlas.DIM_LOCKED
	elif not affordable:
		dim = DmHudAtlas.DIM_HARD
	elif needs != "":
		dim = DmHudAtlas.DIM_SOFT   # only "needs": a lighter dim than out of essence
	if icon_changed or dim != _dim:
		_dim = dim
		_icon.texture = DmHudAtlas.dimmed(icon_path, dim) if dim != 0 else DmHudKit.tex(icon_path)
	var alt_i := 1 if alt else 0
	if alt_i != _kp_alt:
		_kp_alt = alt_i
		_key_panel.add_theme_stylebox_override("panel", DmHudKit.plate(DmUi.INSET, Color(EMBER, 0.45) if alt else DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(5, 0, 5, 0)))
	DmHudKit.set_const(self, "separation", 5)
	var pct := cd_pct(left_ms, total_ms)
	if pct != _drawn_pct:   # the sweep moves in whole percents
		_drawn_pct = pct
		_art.queue_redraw()
	var look := (1 if alt else 0) | (2 if empowered else 0)
	if look != _drawn_look:   # the borders change with the slot's kind only (the pulse and the flash redraw them in _process)
		_drawn_look = look
		_edge.queue_redraw()
	_wake()


## `s.left >= 1000 ? Math.ceil(s.left/1000) : (s.left/1000).toFixed(1)`; empty when ready.
static func cd_text(left: float) -> String:
	if left <= 0.0:
		return ""
	if left >= 1000.0:
		return str(int(ceil(left / 1000.0)))
	return "%.1f" % (left / 1000.0)


## Whole-percent cooldown shade (`--cd`), as the web rounds it.
static func cd_pct(left: float, total: float) -> int:
	if left <= 0.0:
		return 0
	return int(round(left / maxf(total, 1.0) * 100.0))


func flash() -> void:
	_flash = 0.35
	_wake()


## The pulse and the flash are the only per-frame animations; the cooldown sweep follows the 20 Hz view-model.
func _wake() -> void:
	set_process(empowered or _flash > 0.0)


func _process(delta: float) -> void:
	_t += delta
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta)
	if empowered or _flash > 0.0:
		_edge.queue_redraw()
	else:
		set_process(false)
		_edge.queue_redraw()


## The wedge of the cooldown: conic-gradient(rgba(5,4,8,.82) var(--cd), transparent 0), shaded from 12 o'clock clockwise for pct %. Its edge runs along the
## square, so the wedge is a fan from the centre to the points where its outline turns: the start, each corner it passes, and the end (at most five triangles).
func _draw_art() -> void:
	var pct := cd_pct(left_ms, total_ms)
	if pct <= 0:
		return
	var half := BTN * 0.5
	var c := Vector2(half, half)
	var a0 := -PI * 0.5
	var a1 := a0 + TAU * pct / 100.0
	_sweep.clear()
	var prev := _square_point(a0, c, half)
	var col := Color(0.0196, 0.0157, 0.0314, 0.82)
	# the corners lie at -135, -45, 45, 135 degrees (and a turn on): the ones between the start and the end
	var corner := -PI * 0.75
	while corner < a1 - 0.0001:
		if corner > a0 + 0.0001:
			var q := _square_point(corner, c, half)
			_sweep.tri(c, prev, q, col)
			prev = q
		corner += PI * 0.5
	_sweep.tri(c, prev, _square_point(a1, c, half), col)
	_sweep.submit(_art)


## The point where the ray from `c` at angle `a` leaves the square of half side `half`.
static func _square_point(a: float, c: Vector2, half: float) -> Vector2:
	var d := Vector2(cos(a), sin(a))
	return c + d * (half / maxf(absf(d.x), absf(d.y)))


## border + inset 2px #07060a, and the empowered pulse and the cast flash over them.
func _draw_edge() -> void:
	var r := Rect2(Vector2.ZERO, Vector2(BTN, BTN))
	var border := Color(DmUi.BONE_300, 0.35)
	var inset := Color("07060a")
	if alt:
		border = Color(EMBER, 0.55)
	if empowered:
		border = JADE
	DmHudKit.outline(_edge, r.grow(-1.0), inset, 2.0)
	DmHudKit.outline(_edge, r, border, 1.0)
	if empowered:
		var k := 0.5 + 0.5 * cos(_t / 1.4 * TAU)
		for i in 4:
			DmHudKit.outline(_edge, r.grow(-1.0 - i), Color(JADE, (0.5 * k + 0.12) * (1.0 - i / 4.0) * 0.5), 1.0)
	if _flash > 0.0:
		for i in 4:
			DmHudKit.outline(_edge, r.grow(-1.0 - i), Color(DmUi.SPELL_300, 0.8 * (_flash / 0.35) * (1.0 - i / 4.0)), 1.0)
