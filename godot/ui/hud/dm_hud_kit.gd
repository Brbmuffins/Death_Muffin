class_name DmHudKit
extends RefCounted
## Small builders shared by the HUD widgets (labels with the web's text-shadow, panels, number formats). Pure helpers.

const ART := "res://ui/hud/art/"
const SHADOW := Color(0, 0, 0, 1)

static var _tex: Dictionary = {}


## Theme overrides only when the value differs: every add_theme_*_override fires a theme change that re-lays the control's
## container, and the HUD applies its view-model every frame (that was most of a ~3 ms hud.apply).
static func set_color(c: Control, name: StringName, col: Color) -> void:
	if c.has_theme_color_override(name) and c.get_theme_color(name) == col:
		return
	c.add_theme_color_override(name, col)


static func set_const(c: Control, name: StringName, v: int) -> void:
	if c.has_theme_constant_override(name) and c.get_theme_constant(name) == v:
		return
	c.add_theme_constant_override(name, v)


static func set_font_size(c: Control, name: StringName, v: int) -> void:
	if c.has_theme_font_size_override(name) and c.get_theme_font_size(name) == v:
		return
	c.add_theme_font_size_override(name, v)


static func tex(path: String) -> Texture2D:
	if path == "":
		return null
	if _tex.has(path):
		return _tex[path]
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path) as Texture2D
	_tex[path] = t
	return t


## Chrome glyph (archive/legacy-web:src/ui/icons.ts) as a texture: skull crown bag anvil gear waymap skills grimoire atlas book ...
static func icon(name: String) -> Texture2D:
	return tex(ART + "icons/" + name + ".svg")


## A Label in the HUD's look: size px, colour, font kind (DmUi.font), optional `text-shadow: 0 1px 3px #000`.
static func lbl(text: String, size: int = 14, color: Color = DmUi.BONE_100, font: String = "body", shadow: bool = true, spacing: float = 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", DmUi.font(font))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if shadow:
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("shadow_offset_x", 0)
		l.add_theme_constant_override("shadow_offset_y", 1)
	if spacing != 0.0:
		l.add_theme_font_override("font", spaced(font, spacing))
	return l


## Letter-spaced font (CSS letter-spacing in px; Godot spacing is whole pixels on the glyph advance).
static func spaced(base: String, px: float) -> Font:
	var fv := FontVariation.new()
	fv.base_font = DmUi.font(base)
	fv.spacing_glyph = int(round(px))
	return fv


static func panel(bg: Color, border: Color = Color(0, 0, 0, 0), widths: Vector4 = Vector4(1, 1, 1, 1), pad: Vector4 = Vector4(0, 0, 0, 0), radius: int = 0) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", style(bg, border, widths, pad, radius))
	return p


## widths = (left, top, right, bottom); pad = (left, top, right, bottom)
static func style(bg: Color, border: Color = Color(0, 0, 0, 0), widths: Vector4 = Vector4(1, 1, 1, 1), pad: Vector4 = Vector4(0, 0, 0, 0), radius: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_left = int(widths.x)
	sb.border_width_top = int(widths.y)
	sb.border_width_right = int(widths.z)
	sb.border_width_bottom = int(widths.w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad.x
	sb.content_margin_top = pad.y
	sb.content_margin_right = pad.z
	sb.content_margin_bottom = pad.w
	return sb


## Absolute placement: anchors (ax, ay) with the control's own edge placed `ox, oy` from them. gh/gv: which way it grows.
static func place(c: Control, ax: float, ay: float, ox: float, oy: float, gh: int = Control.GROW_DIRECTION_END, gv: int = Control.GROW_DIRECTION_END) -> void:
	c.anchor_left = ax
	c.anchor_right = ax
	c.anchor_top = ay
	c.anchor_bottom = ay
	c.grow_horizontal = gh
	c.grow_vertical = gv
	c.offset_left = ox
	c.offset_right = ox
	c.offset_top = oy
	c.offset_bottom = oy


## 1234567 -> "1,234,567" (JS toLocaleString, en-US integers).
static func commas(n: float) -> String:
	var v := int(n)
	var s := str(absi(v))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if v < 0 else "") + out


static func html(c: Color) -> String:
	return "#" + c.to_html(false)


## "#rrggbb" string, Color, or 0xRRGGBB int -> Color
static func color_of(v: Variant, fallback: Color = Color.WHITE) -> Color:
	if v is Color:
		return v
	if v is String and v != "":
		return Color(v)
	if v is int:
		return Color.hex((int(v) << 8) | 0xFF)
	return fallback


static func mix(a: Color, b: Color, t: float) -> Color:
	return a.lerp(b, t)
