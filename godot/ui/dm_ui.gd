class_name DmUi
extends RefCounted
## Design tokens + small helpers for the Death Muffin UI kit. Mirrors src/theme/tokens.css (web is the spec).
## Everything here is static: `DmUi.BONE_100`, `DmUi.rarity_color("epic")`, `DmUi.theme()`.

# --- World materials (tokens.css) -------------------------------------------------------------
const VOID_950 := Color("07060a")
const OBSIDIAN_900 := Color("0d0b11")
const PLUM_850 := Color("17101d")
const PLUM_750 := Color("25162f")
const STONE_700 := Color("24202b")
const STONE_500 := Color("5e5968")
const BONE_300 := Color("d8cfbd")
const BONE_100 := Color("f0e9dc")
const SILVER_400 := Color("96a0b5")
const VEIL_500 := Color("7c3aed")
const SPELL_400 := Color("9b5cff")
const SPELL_300 := Color("c6a4ff")
const SPIRIT_400 := Color("8f9ed1")
const IRON_500 := Color("4b4654")
const BLOOD_600 := Color("4a2d35")
const BLOOD_500 := Color("6e2f45")
const ROT_400 := Color("8fa05a")

# --- Semantic surfaces (the color-mix() results of tokens.css, precomputed) ----------------------
const PANEL := Color("0e0c12")            # obsidian 90% / plum 10%
const INSET := Color("09060c")            # 60% black over plum (opaque)
const BORDER := Color(0.8471, 0.8118, 0.7412, 0.20)         # bone-300 @ 20%
const BORDER_STRONG := Color(0.8471, 0.8118, 0.7412, 0.38)  # bone-300 @ 38%
const BORDER_ACTIVE := Color("a875f0")    # spell-400 78% / bone-300
const SLOT_BORDER := Color(0.8471, 0.8118, 0.7412, 0.10)    # .cw-slot idle border
const TEXT := BONE_100
const TEXT_MUTED := Color(0.8471, 0.8118, 0.7412, 0.80)
const TEXT_FAINT := Color(0.8471, 0.8118, 0.7412, 0.60)
const ACCENT_SOFT := Color(0.6078, 0.3608, 1.0, 0.16)       # spell-400 @ 16%
const DANGER := Color("c77b8f")
const OK := Color("a9c28a")
const FOCUS := SPIRIT_400
const GOLD := Color("e2c98f")             # the web's "gold" accent (sell value, locks, NEW pips)
const UP := Color("8fe36a")               # upgrade verdict / arrow
const DOWN := Color("ff7b6b")             # downgrade verdict (compare rows use #d97a6b)
const DOWN_SOFT := Color("d97a6b")
const BREW := Color("e6d3a0")
const PANEL_SHADOW := Color(0, 0, 0, 0.62)

# --- Rarity (src/content/items.ts RARITY_COLOR / RARITY_MARK) ------------------------------------
const RARITY_COLOR := {
	"common": Color("b9b2a4"),
	"uncommon": Color("8fb98a"),
	"rare": Color("8fa6e8"),
	"epic": Color("c6a4ff"),
	"legendary": Color("ff9a2e"),
}
const RARITY_MARK := {"common": "·", "uncommon": "◆", "rare": "◆◆", "epic": "◆◆◆", "legendary": "★"}
const RARITY_ORDER: Array[String] = ["common", "uncommon", "rare", "epic", "legendary"]

const THEME_PATH := "res://ui/theme/dm_theme.tres"
const FONT_DIR := "res://ui/fonts/"

static var _theme: Theme
static var _fonts: Dictionary = {}


static func theme() -> Theme:
	if _theme == null:
		_theme = load(THEME_PATH) as Theme
	return _theme


static func rarity_color(rarity: String) -> Color:
	return RARITY_COLOR.get(rarity, RARITY_COLOR["common"])


static func rarity_mark(rarity: String) -> String:
	return RARITY_MARK.get(rarity, "")


## "display" (Cormorant Garamond 600), "display_bold", "display_italic", "body" (Alegreya Sans 400),
## "body_bold", "body_medium", "body_italic", "numeric" (IBM Plex Sans Condensed 600), "numeric_medium".
static func font(kind: String) -> Font:
	if _fonts.has(kind):
		return _fonts[kind]
	var file := ""
	match kind:
		"display": file = "cormorant-garamond-latin-600-normal.woff2"
		"display_medium": file = "cormorant-garamond-latin-500-normal.woff2"
		"display_bold": file = "cormorant-garamond-latin-700-normal.woff2"
		"display_italic": file = "cormorant-garamond-latin-500-italic.woff2"
		"body": file = "alegreya-sans-latin-400-normal.woff2"
		"body_medium": file = "alegreya-sans-latin-500-normal.woff2"
		"body_bold": file = "alegreya-sans-latin-700-normal.woff2"
		"body_italic": file = "alegreya-sans-latin-400-italic.woff2"
		"numeric": file = "ibm-plex-sans-condensed-latin-600-normal.woff2"
		"numeric_medium": file = "ibm-plex-sans-condensed-latin-500-normal.woff2"
		_: file = "alegreya-sans-latin-400-normal.woff2"
	var f: Font = load(FONT_DIR + file)
	_fonts[kind] = f
	return f


# --- small builders ----------------------------------------------------------------------------

## Web `text-transform: uppercase` (Godot labels cannot do it): apply when setting text.
static func upper(s: String) -> String:
	return s.to_upper()


static func box(bg: Color, border: Color = Color(0, 0, 0, 0), border_w: int = 1, radius: int = 2, margin: Vector2 = Vector2.ZERO) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w if border.a > 0.0 else 0)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = margin.x
	sb.content_margin_right = margin.x
	sb.content_margin_top = margin.y
	sb.content_margin_bottom = margin.y
	return sb


static func label(text: String, variation: String = "", autowrap: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	if autowrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


static func hrule(color: Color = BORDER) -> Control:
	var c := ColorRect.new()
	c.color = color
	c.custom_minimum_size = Vector2(0, 1)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func spacer(h: float = 0.0, w: float = 0.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func gold(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if n < 0 else "") + out + "g"


## The web's tiny HTML (`<b>`, `<i>`, `<kbd>`, `<br>`, entities) as Godot BBCode for a RichTextLabel.
## Key caps use [bgcolor] since RichTextLabel cannot draw borders.
static func markup(html: String, kbd_color: Color = SPELL_300) -> String:
	var s := html.replace("[", "[lb]")
	s = s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&middot;", "·")
	s = s.replace("<br>", "\n").replace("<br/>", "\n")
	s = s.replace("<b>", "[b][color=#%s]" % BONE_100.to_html(false)).replace("</b>", "[/color][/b]")
	s = s.replace("<strong>", "[b]").replace("</strong>", "[/b]")
	s = s.replace("<i>", "[i]").replace("</i>", "[/i]").replace("<em>", "[i]").replace("</em>", "[/i]")
	s = s.replace("<kbd>", "[font=%s][bgcolor=#07060a99][color=#%s] " % [FONT_DIR + "ibm-plex-sans-condensed-latin-600-normal.woff2", kbd_color.to_html(false)])
	s = s.replace("</kbd>", " [/color][/bgcolor][/font]")
	s = s.replace("<code>", "[code]").replace("</code>", "[/code]")
	return s


static func new_pip(text: String = "NEW") -> PanelContainer:
	## The gold NEW pip (.dm-pip).
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(GOLD, Color(0, 0, 0, 0), 0, 0, Vector2(5, 0)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font("numeric"))
	l.add_theme_font_size_override("font_size", 9)
	l.add_theme_color_override("font_color", Color("1a1206"))
	p.add_child(l)
	return p


## A key cap (`kbd`): numeric 600, bone-100, 1px border, 2px bottom, padding 0 5.
static func kbd(text: String, font_size: int = 13) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := box(Color(VOID_950, 0.55), BORDER, 1, 2, Vector2(5, 0))
	sb.border_width_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", font("numeric"))
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", BONE_100)
	p.add_child(l)
	return p
