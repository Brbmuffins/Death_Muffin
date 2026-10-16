class_name DmFrontUi
extends RefCounted
## Small builders shared by the login / discipline-select screens (ui.css .cw-front family). Static only.

const ORANGE := Color("e8b789")        # login kicker / link accent
const ORANGE_BORDER := Color("b77b57")
const ORANGE_CORNER := Color("ce8d61")
const EMBER := Color("f1b481")         # h1 <em>
const LEGIBLE_SHADOW := Color(0, 0, 0, 0.95)


static func fv(kind: String, spacing_px: float = 0.0) -> Font:
	var base := DmUi.font(kind)
	if spacing_px == 0.0:
		return base
	var v := FontVariation.new()
	v.base_font = base
	v.spacing_glyph = int(round(spacing_px))
	return v


## A themed Label with explicit font/size/colour (the CSS classes of the front screens are one-offs, not theme variations).
static func lbl(text: String, kind: String, size: int, color: Color, spacing_px: float = 0.0, wrap: bool = false, shadow: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", fv(kind, spacing_px))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if shadow:
		l.add_theme_color_override("font_shadow_color", LEGIBLE_SHADOW)
		l.add_theme_constant_override("shadow_offset_x", 0)
		l.add_theme_constant_override("shadow_offset_y", 1)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func capitalize_first(s: String) -> String:
	if s.is_empty():
		return s
	return s.substr(0, 1).to_upper() + s.substr(1)


## Horizontal 3-stop gradient overlay (css linear-gradient(90deg, a, b 56%, c)).
static func h_gradient(a: Color, b: Color, b_at: float, c: Color) -> TextureRect:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, b_at, 1.0])
	g.colors = PackedColorArray([a, b, c])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	gt.width = 256
	gt.height = 4
	var tr := TextureRect.new()
	tr.texture = gt
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return tr


static func backdrop(path: String = "res://front/art/login-backdrop-pyre.webp") -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = load(path)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.modulate = Color("e8dfe0")
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return tr
