class_name DmSpellCard
extends PanelContainer
## `.hud-spell-tooltip.cw-plate` (HUD.refreshTooltip): the spell card shown over a HUD slot. Data from DmSpellTooltip.build + the UI's extras:
##   {name, control, status, status_kind: ""|"locked"|"empowered", description, metrics:[{label,value}], targeting, details:[String],
##    rune: {icon: Texture2D|null, name, lines, cost} or {}, tip, footer}
## Width min(420, viewport - 24), height capped at min(580, viewport - 24) with a scroll (the card takes the mouse so long text scrolls).

const PAD := Vector2(19, 17)
const BODY := 15

var scroll: ScrollContainer
var _v: VBoxContainer
var _max_h := 580.0
var _w := 420.0


func _init() -> void:
	theme = DmUi.theme()
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := DmUi.box(Color(0.0275, 0.0235, 0.0392, 0.98), DmUi.BORDER_STRONG, 1, 3, Vector2.ZERO)
	sb.shadow_color = DmUi.PANEL_SHADOW
	sb.shadow_size = 30
	sb.shadow_offset = Vector2(0, 14)
	add_theme_stylebox_override("panel", sb)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", int(PAD.x))
	m.add_theme_constant_override("margin_right", int(PAD.x))
	m.add_theme_constant_override("margin_top", int(PAD.y))
	m.add_theme_constant_override("margin_bottom", int(PAD.y))
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(m)
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	m.add_child(scroll)
	_v = VBoxContainer.new()
	_v.add_theme_constant_override("separation", 0)
	_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(_v)
	add_child(DmCorners.new())


func _txt(text: String, size: int, color: Color, font: String = "body") -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", DmUi.font(font))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("line_spacing", 3 if size >= 14 else 2)
	return l


func _gap(h: float) -> void:
	_v.add_child(DmUi.spacer(h))


func build(d: Dictionary, vp: Vector2) -> void:
	_w = minf(420.0, vp.x - 24.0)
	_max_h = minf(580.0, vp.y - 24.0)
	custom_minimum_size.x = _w
	_v.custom_minimum_size.x = _w - PAD.x * 2.0
	for c in _v.get_children():
		_v.remove_child(c)
		c.queue_free()
	_v.add_child(_txt(String(d["name"]), 23, DmUi.BONE_100, "display"))
	_gap(3)
	_v.add_child(_txt(String(d["control"]), BODY, DmUi.BONE_300))
	_gap(7)
	var sk: String = String(d.get("status_kind", ""))
	_v.add_child(_txt(String(d["status"]), 14, Color("9ff5e0") if sk == "empowered" else (Color("e2c98f") if sk == "locked" else DmUi.TEXT_MUTED)))
	_gap(10)
	_v.add_child(_txt(String(d["description"]), BODY, DmUi.TEXT))
	_gap(10)
	# .spell-metrics: 2 columns, gap 7 14, padding 10 0, 1px border top and bottom
	_v.add_child(DmUi.hrule())
	_gap(10)
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 14)
	g.add_theme_constant_override("v_separation", 7)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for m in d["metrics"]:
		var cell := HBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var a := _txt(String(m["label"]), BODY, DmUi.TEXT_MUTED)
		a.autowrap_mode = TextServer.AUTOWRAP_OFF
		cell.add_child(a)
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(sp)
		var b := _txt(String(m["value"]), BODY, DmUi.BONE_100, "numeric_medium")
		b.autowrap_mode = TextServer.AUTOWRAP_OFF
		b.size_flags_horizontal = Control.SIZE_SHRINK_END
		cell.add_child(b)
		g.add_child(cell)
	_v.add_child(g)
	_gap(10)
	_v.add_child(DmUi.hrule())
	_gap(10)
	_v.add_child(_txt(String(d["targeting"]), BODY, DmUi.SPELL_300))
	_gap(10)
	var first := true
	for line in d["details"]:
		if not first:
			_gap(7)
		first = false
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bullet := _txt("•", BODY, DmUi.TEXT)
		bullet.autowrap_mode = TextServer.AUTOWRAP_OFF
		bullet.custom_minimum_size.x = 19
		bullet.size_flags_horizontal = Control.SIZE_FILL
		bullet.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(bullet)
		row.add_child(_txt(String(line), BODY, DmUi.TEXT))
		_v.add_child(row)
	_gap(10)
	var rune: Dictionary = d.get("rune", {})
	if not rune.is_empty():
		var box := PanelContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_theme_stylebox_override("panel", DmUi.box(Color(0.1216, 0.5608, 0.5255, 0.12), Color(0.4353, 0.8902, 0.7843, 0.45), 1, 0, Vector2(8, 6)))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var img := TextureRect.new()
		img.texture = rune.get("icon")
		img.custom_minimum_size = Vector2(32, 32)
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		img.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(img)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(_txt(String(rune["name"]), 12, Color("9ff5e0"), "body_bold"))
		var rt := RichTextLabel.new()
		rt.bbcode_enabled = true
		rt.fit_content = true
		rt.scroll_active = false
		rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rt.add_theme_font_override("normal_font", DmUi.font("body"))
		rt.add_theme_font_size_override("normal_font_size", 11)
		rt.add_theme_color_override("default_color", Color("e8dec6"))
		var txt := String(rune["lines"]).replace("[", "[lb]")
		if String(rune.get("cost", "")) != "":
			txt += " [color=#e7b07a]%s[/color]" % String(rune["cost"]).replace("[", "[lb]")
		rt.text = txt
		col.add_child(rt)
		h.add_child(col)
		box.add_child(h)
		_v.add_child(box)
		_gap(8)
	# .spell-tip: border-top, padding-top 11
	_v.add_child(DmUi.hrule())
	_gap(11)
	_v.add_child(_txt("Combat tip", BODY, DmUi.BONE_300, "body_bold"))
	_gap(4)
	_v.add_child(_txt(String(d["tip"]), BODY, DmUi.TEXT_MUTED))
	_gap(11)
	_v.add_child(_txt(String(d["footer"]), 13, DmUi.TEXT_FAINT))
	_fit()


## The scroll area is as tall as its text, up to the web's max-height.
func _fit() -> void:
	var inner_h := _v.get_combined_minimum_size().y
	scroll.custom_minimum_size.y = minf(inner_h, _max_h - PAD.y * 2.0)


func _process(_d: float) -> void:
	if is_visible_in_tree():
		_fit()
