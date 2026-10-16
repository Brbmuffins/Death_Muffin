class_name DmPa
extends RefCounted
## Shared builders for the "panels A" track (Ascension, Atlas, Class, Codex, Grimoire, Legion, Cosmetics, Dialogue, Waystones, Sheet).
## All static, all built on the ui-kit tokens (DmUi) and theme variations. Panels stay pure: Dictionary data in, signals out.
##
## Test hooks: interactive nodes carry meta "act" (what pressing does) and optionally "arg"; DmPa.find_all(root, "act") collects them.

const MUTED := Color(0.8471, 0.8118, 0.7412, 0.80)


## Remove all children NOW (queue_free alone leaves them in get_children() until the frame ends).
static func clear(n: Node) -> void:
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


static func text(s: String, size: int = 14, color: Color = DmUi.TEXT_MUTED, font: String = "body", wrap: bool = true) -> Label:
	var l := Label.new()
	l.text = s
	l.add_theme_font_override("font", DmUi.font(font))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.custom_minimum_size.x = 40
	return l


## A display-font heading (web h3: Cormorant, uppercase, tracked).
static func heading(s: String, size: int = 15, color: Color = DmUi.BONE_300, upper: bool = true) -> Label:
	var l := text(DmUi.upper(s) if upper else s, size, color, "display_bold", false)
	l.add_theme_constant_override("outline_size", 0)
	return l


## Numeric-font label (IBM Plex Condensed).
static func num(s: String, size: int = 13, color: Color = DmUi.BONE_100) -> Label:
	return text(s, size, color, "numeric", false)


## Small-caps "k" label (web `.k`: 11px muted uppercase, tracked).
static func kicker(s: String) -> Label:
	return text(DmUi.upper(s), 11, DmUi.TEXT_MUTED, "body", false)


## HTML-ish markup (<b>, <i>, <kbd>, <br>) as a RichTextLabel that wraps and sizes itself.
static func rich(html: String, size: int = 14, color: Color = DmUi.TEXT_MUTED) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.custom_minimum_size.x = 40
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	r.add_theme_font_size_override("italics_font_size", size)
	r.add_theme_font_size_override("bold_italics_font_size", size)
	r.add_theme_color_override("default_color", color)
	r.text = DmUi.markup(html)
	return r


## Like rich() but the text is already BBCode (no HTML conversion): for coloured runs.
static func rich_bb(bbcode: String, size: int = 14, color: Color = DmUi.TEXT_MUTED) -> RichTextLabel:
	var r := rich("", size, color)
	r.text = bbcode
	return r


static func margin(c: Control, l: int = 0, t: int = 0, r: int = 0, b: int = 0) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	m.add_child(c)
	return m


static func vbox(sep: int = 6) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return v


static func hbox(sep: int = 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func flow(h: int = 6, v: int = 6) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", h)
	f.add_theme_constant_override("v_separation", v)
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return f


static func grid(cols: int, h: int = 8, v: int = 8) -> GridContainer:
	var g := GridContainer.new()
	g.columns = cols
	g.add_theme_constant_override("h_separation", h)
	g.add_theme_constant_override("v_separation", v)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return g


## A button. kind: "" (cw-button), "small", "primary", "small_primary". `act`/`arg` are the test/hook meta.
static func button(label: String, kind: String = "", disabled: bool = false, act: String = "", arg: Variant = null) -> Button:
	var b := Button.new()
	b.text = DmUi.upper(label)
	b.focus_mode = Control.FOCUS_NONE
	match kind:
		"small": b.theme_type_variation = "DmButtonSmall"
		"primary": b.theme_type_variation = "DmButtonPrimary"
		"small_primary": b.theme_type_variation = "DmButtonSmallPrimary"
	b.disabled = disabled
	if act != "":
		b.set_meta("act", act)
	if arg != null:
		b.set_meta("arg", arg)
	return b


## A filter chip (web .cw-chip): a toggle-looking small button.
static func chip(label: String, on: bool, act: String = "", arg: Variant = null) -> Button:
	var b := button(label, "small", false, act, arg)
	b.toggle_mode = true
	b.set_pressed_no_signal(on)
	b.text = label
	return b


## An inset card (web: inset bg + 1px border). Returns the PanelContainer; its content VBox is `card_body(c)`.
static func card(border: Color = DmUi.BORDER, bg: Color = DmUi.INSET, pad: Vector2 = Vector2(12, 10), radius: int = 0, border_w: int = 1) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", DmUi.box(bg, border, border_w, radius, pad))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	return p


static func card_body(c: PanelContainer) -> VBoxContainer:
	return c.get_child(0) as VBoxContainer


static func hrule(c: Color = DmUi.BORDER) -> Control:
	return DmUi.hrule(c)


## Table: header row + rows (each an Array of strings). `ratios` = stretch per column (default 1). Numeric columns right-aligned via `right`.
static func table(headers: Array, rows: Array, ratios: Array = [], right: Array = []) -> Control:
	var g := GridContainer.new()
	g.columns = headers.size()
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 4)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in headers.size():
		var l := text(DmUi.upper(str(headers[i])), 11, DmUi.TEXT_FAINT, "body_bold", false)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if right.has(i):
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		g.add_child(l)
	for r in rows:
		for i in headers.size():
			var l := text(str(r[i]) if i < r.size() else "", 13, DmUi.BONE_300, "body", true)
			if right.has(i):
				l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			if i < ratios.size():
				l.size_flags_stretch_ratio = float(ratios[i])
			g.add_child(l)
	return g


## <dl>: term (small display caps) / definition (markup) pairs.
static func dl(pairs: Array) -> Control:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 4)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in pairs:
		var dt := text(DmUi.upper(str(p[0])), 12, Color("aab3c6"), "display", false)
		dt.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		g.add_child(dt)
		g.add_child(rich(str(p[1]), 14))
	return g


static func icon(path: String, px: int = 52, seed_text: String = "", glyph: String = "") -> DmPaIcon:
	var i := DmPaIcon.new()
	i.setup(path, px, seed_text if seed_text != "" else path, glyph)
	return i


## Colour swatches (the rite colour identity chips).
static func swatches(colors: Array) -> Control:
	var h := hbox(3)
	for c in colors:
		var r := ColorRect.new()
		r.color = Color(str(c))
		r.custom_minimum_size = Vector2(14, 14)
		h.add_child(r)
	return h


## "1,234" with thousands separators (toLocaleString).
static func commas(n: Variant) -> String:
	var v: int = int(floor(float(n)))
	var s := str(absi(v))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if v < 0 else "") + out


## `+${(x*100).toFixed(1) stripped}%` (the web's pct()).
static func pct(x: float) -> String:
	return strip_zeros(x * 100.0, 1) + "%"


## JS `+x.toFixed(d)`: round to d decimals and drop trailing zeros.
static func strip_zeros(x: float, d: int = 1) -> String:
	var s: String = ("%." + str(d) + "f") % x
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s


## Chance as the Atlas prints it (atlas.ts fmtChance).
static func fmt_chance(p: float) -> String:
	var v: float = p * 100.0
	if v >= 99.995:
		return "100%"
	var d := 3
	if v >= 10.0:
		d = 1
	elif v >= 0.1:
		d = 2
	return strip_zeros(v, d) + "%"


## "1 in 250" for a chance under 5% (atlas.ts oneIn), else "".
static func one_in(p: float) -> String:
	if p > 0.0 and p < 0.05:
		return "1 in " + commas(roundf(1.0 / p))
	return ""


static func fmt_qty(lo: int, hi: int) -> String:
	return str(lo) if lo == hi else "%d-%d" % [lo, hi]


static func find_all(root: Node, meta_key: String, out: Array = []) -> Array:
	for c in root.get_children():
		if c.has_meta(meta_key):
			out.append(c)
		find_all(c, meta_key, out)
	return out


## First node under `root` whose meta `act` equals `act` (and `arg` equals `arg` when given).
static func find_act(root: Node, act: String, arg: Variant = null) -> Node:
	for n in find_all(root, "act"):
		if n.get_meta("act") == act and (arg == null or n.get_meta("arg", null) == arg):
			return n
	return null


static func acts(root: Node, act: String) -> Array:
	return find_all(root, "act").filter(func(n: Node) -> bool: return n.get_meta("act") == act)


## Every Label/RichTextLabel/Button text under `root`, joined: for "is this text on screen" tests.
static func all_text(root: Node) -> String:
	var parts: PackedStringArray = []
	_collect_text(root, parts)
	return "\n".join(parts)


static func _collect_text(n: Node, parts: PackedStringArray) -> void:
	if n is RichTextLabel:
		parts.append((n as RichTextLabel).get_parsed_text())
	elif n is Label:
		parts.append((n as Label).text)
	elif n is Button:
		parts.append((n as Button).text)
	for c in n.get_children():
		_collect_text(c, parts)


## Drops or keeps `{auto}...{/auto}` help text (settings.ts gateAuto: auto combat is owner-only).
static func gate_auto(t: String, allowed: bool) -> String:
	var re := RegEx.new()
	re.compile("\\{auto\\}([\\s\\S]*?)\\{/auto\\}")
	var out := t
	for m in re.search_all(t):
		out = out.replace(m.get_string(0), m.get_string(1) if allowed else "")
	return out


## Text of the first node with meta act == `act` (button caption), or "".
static func act_text(root: Node, act: String) -> String:
	var n := find_act(root, act)
	return (n as Button).text if n is Button else ""
