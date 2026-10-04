class_name DmPb
extends RefCounted
## Shared builders for the crafting / gathering / economy panels (panels_b). Pure UI helpers: no game rules, no network.
## Numbers in the cards come from the rules modules (DmGathering, DmLabor, DmGarden, DmSalvage ...), never from here.

const GLYPH := "◆"


## Detach and free every child immediately (queue_free alone leaves them counted until the frame ends).
static func clear(n: Node) -> void:
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


## A plain label: size px, colour, font kind ("body", "body_bold", "numeric", "display"...).
static func text(s: String, size: int = 14, color: Color = DmUi.TEXT_MUTED, font: String = "body", wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = s
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_override("font", DmUi.font(font))
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


## Muted wrapped paragraph (`.cw-hint-text` 13px faint, or `.cw-codex-note` 12px muted).
static func hint(s: String, size: int = 13, color: Color = DmUi.TEXT_FAINT) -> Label:
	return text(s, size, color, "body", true)


## Wrapped paragraph with the web's tiny markup (<b>, <i>) via RichTextLabel.
static func rich(markup: String, size: int = 13, color: Color = DmUi.TEXT_MUTED) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	r.add_theme_font_size_override("italics_font_size", size)
	r.add_theme_color_override("default_color", color)
	r.add_theme_font_override("normal_font", DmUi.font("body"))
	r.add_theme_font_override("bold_font", DmUi.font("body_bold"))
	r.add_theme_font_override("italics_font", DmUi.font("body_italic"))
	r.text = DmUi.markup(markup)
	return r


static func button(label: String, primary: bool = false, disabled: bool = false, tip: String = "") -> Button:
	var b := Button.new()
	b.text = DmUi.upper(label)
	b.theme_type_variation = "DmButtonSmallPrimary" if primary else "DmButtonSmall"
	b.focus_mode = Control.FOCUS_NONE
	b.disabled = disabled
	b.tooltip_text = tip
	return b


static func margin(c: Control, l: int = 0, t: int = 0, r: int = 0, b: int = 0) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	m.add_child(c)
	return m


static func vbox(sep: int = 4) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return v


static func hbox(sep: int = 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func grow(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


## Inset card (`var(--cw-inset)` + 1px border, optional 3px left accent). Adds itself to `parent` and returns the VBox to fill.
static func card(parent: Control, border: Color = DmUi.BORDER, accent: Color = Color(0, 0, 0, 0), pad: Vector2 = Vector2(10, 8), bg: Color = DmUi.INSET) -> VBoxContainer:
	var p := PanelContainer.new()
	var sb := DmUi.box(bg, border, 1, 0, Vector2.ZERO)
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 0)
	p.add_child(h)
	if accent.a > 0.0:
		var a := ColorRect.new()
		a.color = accent
		a.custom_minimum_size = Vector2(3, 0)
		a.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(a)
	var v := vbox(4)
	var m := margin(v, int(pad.x), int(pad.y), int(pad.x), int(pad.y))
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(m)
	parent.add_child(p)
	v.set_meta("panel", p)
	return v


## Item icon tile: bordered square in the rarity colour holding the texture, or the ◆ glyph when there is no art.
static func icon(rarity: String, size: float = 40.0, tex: Texture2D = null, dim: bool = false) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var rc := DmUi.rarity_color(rarity)
	p.add_theme_stylebox_override("panel", DmUi.box(Color(rc, 0.10), Color(rc, 0.45 if not dim else 0.2), 1, 0, Vector2.ZERO))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if tex != null:
		var t := TextureRect.new()
		t.texture = tex
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if dim:
			t.modulate = Color(0, 0, 0, 0.55)
		p.add_child(t)
	else:
		var l := text(GLYPH, int(size * 0.5), Color(rc, 0.9 if not dim else 0.35), "body", false)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(l)
	return p


## Section title (`.cw-panel-section-title`): Cormorant uppercase, letter-spaced.
static func section_title(s: String) -> Label:
	var l := DmUi.label(DmUi.upper(s), "DmSub")
	l.add_theme_font_size_override("font_size", 14)
	return l


## "label ........ value" row used in the Ledger lists.
static func kv_row(left: Control, right_text: String, right_color: Color = DmUi.BONE_100) -> HBoxContainer:
	var h := hbox(10)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(left)
	h.add_child(text(right_text, 13, right_color, "numeric"))
	return h


## `toLocaleString()` for integers.
static func num(n: Variant) -> String:
	var s := str(absi(int(n)))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if int(n) < 0 else "") + out


## gatherReport.durationText.
static func duration_text(seconds: int) -> String:
	var h := seconds / 3600
	var m := (seconds % 3600) / 60
	var s := seconds % 60
	if h > 0:
		return "%dh %dm" % [h, m]
	if m > 0:
		return "%dm %ds" % [m, s]
	return "%ds" % s


static func item_name(item_id: String) -> String:
	return String(DmGatherData.item_meta(item_id).get("name", item_id))


static func item_rarity(item_id: String) -> String:
	return String(DmGatherData.item_meta(item_id).get("rarity", "common"))


static func skill_name(skill_id: String) -> String:
	var sk: Dictionary = DmGatherData.get_data()["skills"].get(skill_id, {})
	return String(sk.get("name", skill_id))


## True while the pointer is over a button / dropdown of `root`, or a dropdown is open: the web skips its countdown redraw then so a
## click that started on a control is not lost.
static func pointer_busy(root: Node) -> bool:
	for c in root.find_children("*", "Button", true, false):
		var b := c as Button
		if b.is_hovered() and not b.disabled:
			return true
		if b is OptionButton and (b as OptionButton).get_popup().visible:
			return true
	return false


## One "Brought back" row per item: tinted icon + name left, ×qty right (`.cw-chron-grp .row`). items: [{itemId, name, qty, rarity}].
static func item_rows(parent: Control, items: Array) -> void:
	for i: Dictionary in items:
		var rc := DmUi.rarity_color(String(i.get("rarity", "common")))
		var left := hbox(6)
		var ic := icon(String(i.get("rarity", "common")), 18.0)
		left.add_child(ic)
		var n := text(String(i.get("name", i.get("itemId", ""))), 13, rc)
		n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		left.add_child(n)
		parent.add_child(kv_row(left, "×%s" % num(i.get("qty", 0))))


## The grouped box (`.cw-chron-grp`): inset, small uppercase heading, rows below. Returns the VBox to fill.
static func group(parent: Control, heading: String, upper: bool = true) -> VBoxContainer:
	var v := card(parent, DmUi.BORDER, Color(0, 0, 0, 0), Vector2(10, 8))
	var h := text(DmUi.upper(heading) if upper else heading, 13, DmUi.BONE_300 if upper else DmUi.BONE_100, "display_bold" if upper else "body_bold")
	v.add_child(h)
	return v
