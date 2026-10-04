class_name DmHudSlot
extends VBoxContainer
## One action-bar slot (`.hud-slot`): 62 px icon button with a clockwise cooldown sweep, cooldown seconds, essence cost,
## optional rune badge, plus the key cap under it ("1".."4", "RMB", "R", "LMB"). States: nores (dimmed), empowered (jade pulse),
## locked (grayscale + unlock level), alt (right-click action: ember accent + left rule).
## Driven by `apply(slot_dict)`; see ui/hud/README.md ("slots").

signal pressed          ## left click on the icon (web: click-to-cast)
signal swap_pressed     ## left click on the key cap while `swap` is on

const BTN := 62.0
const EMBER := Color("d0612e")
const JADE := Color("6fe3c8")

var left_ms: float = 0.0
var total_ms: float = 1.0
var affordable: bool = true
var empowered: bool = false
var locked: bool = false
var alt: bool = false
var unlock_level: int = 10
var cost: int = 0
var key_text: String = ""
var swap: bool = false
var icon_path: String = ""
var rune_path: String = ""

var _icon: TextureRect
var _over: Control
var _cdtext: Label
var _cost: Label
var _lock: Label
var _key_panel: PanelContainer
var _key: Label
var _swap_ico: Label
var _rune: TextureRect
var _flash: float = 0.0
var _t: float = 0.0
static var _desat: Shader


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 5)
	alignment = BoxContainer.ALIGNMENT_BEGIN
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(BTN, BTN)
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	holder.clip_contents = true
	holder.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	holder.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit())
	add_child(holder)
	_icon = TextureRect.new()
	_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(_icon)
	_over = Control.new()
	_over.set_anchors_preset(Control.PRESET_FULL_RECT)
	_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_over.draw.connect(_draw_over)
	holder.add_child(_over)
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
	_rune = TextureRect.new()
	_rune.position = Vector2(2, BTN - 2 - 19)
	_rune.size = Vector2(19, 19)
	_rune.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rune.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_rune.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	set_process(true)


func _ensure_shader() -> void:
	if _desat == null:
		_desat = Shader.new()
		_desat.code = "shader_type canvas_item;\nuniform float sat = 1.0;\nuniform float bright = 1.0;\nvoid fragment(){ vec4 c = texture(TEXTURE, UV); float g = dot(c.rgb, vec3(0.299,0.587,0.114)); c.rgb = mix(vec3(g), c.rgb, sat) * bright; COLOR = c; }\n"


## Slot dictionary -> state. Keys: icon key cost left_ms total_ms affordable empowered locked unlock_level alt rune_icon swap.
func apply(s: Dictionary) -> void:
	var new_icon: String = String(s.get("icon", ""))
	if new_icon != icon_path:
		icon_path = new_icon
		_icon.texture = DmHudKit.tex(icon_path)
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
	unlock_level = int(s.get("unlock_level", 10))
	alt = bool(s.get("alt", false))
	swap = bool(s.get("swap", false))
	cost = int(s.get("cost", 0))
	key_text = String(s.get("key", ""))
	_cdtext.text = cd_text(left_ms)
	_cost.text = str(cost) if cost > 0 else ""
	_cost.add_theme_color_override("font_color", Color("9ff5e0") if empowered else (Color("f0b08a") if alt else Color("cbb8ff")))
	_lock.text = str(unlock_level) if locked else ""
	_key.text = key_text
	_key.add_theme_color_override("font_color", Color("f0b08a") if alt else DmUi.BONE_300)
	_key.add_theme_font_size_override("font_size", 10 if alt else 12)
	_swap_ico.visible = swap
	_key_panel.tooltip_text = "Swap this rite (L)" if swap else ""
	_icon.get_parent().tooltip_text = String(s.get("tooltip", ""))
	_ensure_shader()
	if not affordable or locked:
		var m := _icon.material as ShaderMaterial
		if m == null:
			m = ShaderMaterial.new()
			m.shader = _desat
			_icon.material = m
		m.set_shader_parameter("sat", 0.0 if locked else 0.3)
		m.set_shader_parameter("bright", 0.55)
	else:
		_icon.material = null
	_key_panel.add_theme_stylebox_override("panel", DmHudKit.style(DmUi.INSET, Color(EMBER, 0.45) if alt else DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(5, 0, 5, 0)))
	add_theme_constant_override("separation", 5)
	_over.queue_redraw()


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


func _process(delta: float) -> void:
	_t += delta
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta)
	if empowered or _flash > 0.0:
		_over.queue_redraw()


func _draw_over() -> void:
	var r := Rect2(Vector2.ZERO, Vector2(BTN, BTN))
	var pct := cd_pct(left_ms, total_ms)
	if pct > 0:
		# conic-gradient(rgba(5,4,8,.82) var(--cd), transparent 0): shaded from 12 o'clock clockwise for pct %
		var c := r.size * 0.5
		var a1 := -PI * 0.5 + TAU * pct / 100.0
		var pts := PackedVector2Array([c])
		var n := maxi(2, int(pct / 2.0))
		for i in n + 1:
			var a := -PI * 0.5 + (a1 + PI * 0.5) * float(i) / n
			var d := Vector2(cos(a), sin(a))
			# extend to the square's edge so the wedge covers the corners
			var k := 1.0 / maxf(absf(d.x), absf(d.y))
			pts.append(c + d * k * BTN * 0.5)
		_over.draw_colored_polygon(pts, Color(0.0196, 0.0157, 0.0314, 0.82))
	# border + inset 2px #07060a
	var border := Color(DmUi.BONE_300, 0.35)
	var inset := Color("07060a")
	if alt:
		border = Color(EMBER, 0.55)
	if empowered:
		border = JADE
	_over.draw_rect(r.grow(-1.0), inset, false, 2.0)
	_over.draw_rect(r, border, false, 1.0)
	if empowered:
		var k := 0.5 + 0.5 * cos(_t / 1.4 * TAU)
		for i in 4:
			_over.draw_rect(r.grow(-1.0 - i), Color(JADE, (0.5 * k + 0.12) * (1.0 - i / 4.0) * 0.5), false, 1.0)
	if _flash > 0.0:
		for i in 4:
			_over.draw_rect(r.grow(-1.0 - i), Color(DmUi.SPELL_300, 0.8 * (_flash / 0.35) * (1.0 - i / 4.0)), false, 1.0)
