class_name DmBeltPicker
extends PanelContainer
## Port of src/ui/BeltPicker.ts: click a Z / X slot on the HUD belt and choose which brew from the bag it holds. Built on demand. (Dropping a brew
## from the Reliquary onto the slot is DmHud.brew_dropped.)

var ui: Node
var slot_name := ""
var rows: Array = []        ## the choices drawn: {id, label, glyph, color, effect, count, current}
var _vb: VBoxContainer


func _init(ui_: Node = null) -> void:
	ui = ui_
	theme = DmUi.theme()
	add_theme_stylebox_override("panel", DmUi.box(DmUi.PANEL, DmUi.BORDER, 1, 3, Vector2(8, 8)))
	add_child(DmCorners.new())
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_vb = VBoxContainer.new()
	_vb.add_theme_constant_override("separation", 4)
	add_child(_vb)
	custom_minimum_size.x = 260
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	if ui != null:
		ui.windows_root.add_child(self)


static func picker_title(slot_label: String, key: String) -> String:
	return "%s slot · key %s" % [slot_label, key]


static func empty_text(slot_label: String) -> String:
	var kind := slot_label.to_lower()
	return "No %ss in your bag. Brew %s %s in the Alchemist's Wing (the Chapterhouse's east door), then click here again." % [kind, "an" if kind == "elixir" else "a", kind]


func choices(slot: String) -> Array:
	var on := belt_brew(slot)
	var out: Array = []
	for id in DmContent.brews():
		var b: Dictionary = DmContent.brews()[id]
		if b["slot"] == slot and ui.inv.count(id) > 0:
			out.append({"id": id, "label": b["label"], "glyph": b["glyph"], "color": int(b["color"]), "effect": "%s · %ss" % [DmUiBrews.effects_text(b), DmJsFmt.num_str(float(b["seconds"]))],
				"count": ui.inv.count(id), "current": id == on})
	return out


## The brew a belt key drinks: the chosen one while the bag has it, else the first of that slot you carry.
func belt_brew(slot: String) -> String:
	var pick: Variant = ui.belt_pick().get(slot)
	if pick is String and ui.inv.count(pick) > 0:
		return pick
	for id in DmContent.brews():
		if DmContent.brews()[id]["slot"] == slot and ui.inv.count(id) > 0:
			return id
	return ""


func toggle(slot: String) -> void:
	if slot != "elixir" and slot != "tonic":
		return
	if visible:
		close()
		return
	open(slot)


func open(slot: String) -> void:
	close()
	slot_name = "Elixir" if slot == "elixir" else "Tonic"
	var key := "Z" if slot == "elixir" else "X"
	for c in _vb.get_children():
		c.queue_free()
	# .bp-head: display 11px, letter-spacing .16em, uppercase, bone-100, padding 0 2 4, 1px rule beneath
	var head := Label.new()
	head.text = DmUi.upper(picker_title(slot_name, key))
	head.add_theme_font_override("font", DmHudKit.spaced("display", 2.0))
	head.add_theme_font_size_override("font_size", 11)
	head.add_theme_color_override("font_color", DmUi.BONE_100)
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_left", 2)
	hm.add_theme_constant_override("margin_right", 2)
	hm.add_theme_constant_override("margin_bottom", 4)
	hm.add_child(head)
	_vb.add_child(hm)
	_vb.add_child(DmUi.hrule())
	rows = choices(slot)
	if rows.is_empty():
		var em := DmUi.label(empty_text(slot_name), "", true)
		em.add_theme_font_size_override("font_size", 12)
		em.add_theme_color_override("font_color", DmUi.BONE_300)
		em.add_theme_constant_override("line_spacing", 1)
		var emm := MarginContainer.new()
		for side in ["left", "right", "top", "bottom"]:
			emm.add_theme_constant_override("margin_" + side, 2)
		emm.add_child(em)
		_vb.add_child(emm)
	for r in rows:
		_vb.add_child(_row(r))
	var foot := DmUi.label("You can also drag a brew from your bag onto the slot.", "", true)
	foot.add_theme_font_size_override("font_size", 10)
	foot.add_theme_color_override("font_color", DmUi.TEXT_FAINT)
	var fm := MarginContainer.new()
	fm.add_theme_constant_override("margin_top", 2)
	fm.add_child(foot)
	_vb.add_child(fm)
	visible = true
	_place.call_deferred()


## `.bp-row`: glyph (20px, brew colour, glow) | name (13 bold) over effect (11 muted) | "on belt · ×3"; 3px brew-coloured left rule; hover/current tint.
func _row(r: Dictionary) -> Control:
	var col := DmHudKit.color_of(r["color"])
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.custom_minimum_size = Vector2(0, 46)
	var normal := _row_style(col, Color(0.0275, 0.0235, 0.0392, 0.55), DmUi.BORDER, bool(r["current"]))
	var hover := _row_style(col, Color(0.1882, 0.1412, 0.2745, 0.8), DmUi.BORDER_STRONG, false)
	for st in ["normal", "pressed", "focus"]:
		b.add_theme_stylebox_override(st, normal)
	b.add_theme_stylebox_override("hover", hover)
	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 9
	h.offset_right = -6
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var g := DmHudKit.lbl(String(r["glyph"]), 20, col, "body", false)
	g.custom_minimum_size.x = 22
	g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	g.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	g.add_theme_color_override("font_shadow_color", Color(col, 0.8))
	g.add_theme_constant_override("shadow_outline_size", 6)
	h.add_child(g)
	var t := VBoxContainer.new()
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.alignment = BoxContainer.ALIGNMENT_CENTER
	t.add_theme_constant_override("separation", 0)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := DmHudKit.lbl(String(r["label"]), 13, DmUi.BONE_100, "body_bold", false)
	nm.clip_text = true
	t.add_child(nm)
	var ef := DmHudKit.lbl(String(r["effect"]), 11, DmUi.TEXT_MUTED, "body", false)
	ef.clip_text = true
	ef.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.add_child(ef)
	h.add_child(t)
	var n := DmHudKit.lbl("%s×%d" % ["on belt · " if r["current"] else "", int(r["count"])], 12, Color("efe6d0"), "numeric", false)
	n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(n)
	b.add_child(h)
	var id: String = r["id"]
	b.pressed.connect(func() -> void:
		close()
		ui.set_belt(id))
	return b


static func _row_style(col: Color, bg: Color, border: Color, current: bool) -> StyleBoxFlat:
	var sb := DmHudKit.style(Color(0.1569, 0.1176, 0.2275, 0.7) if current else bg, border, Vector4(3, 1, 1, 1), Vector4(0, 0, 0, 0), 3)
	sb.border_blend = false
	return sb


## `.belt-picker { left: calc(100% + 10px); bottom: 0 }` of the belt box: right of it, bottom edges level.
func _place() -> void:
	if ui == null or not visible:
		return
	var chips := ui.hud.brews_box as Control
	reset_size()
	position = Vector2(chips.global_position.x + chips.size.x + 10.0, chips.global_position.y + chips.size.y - size.y)
	position.y = maxf(8.0, position.y)


func close() -> void:
	visible = false


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and not get_global_rect().has_point(event.position):
		# a click on a belt chip is the toggle (HUD.bindBelt), not an outside click (BeltPicker.onDown ignores `[data-brew]`)
		var on_chip := false
		if ui != null and ui.hud != null:
			for c in (ui.hud.brew_row as Control).get_children():
				if (c as Control).get_global_rect().has_point(event.position):
					on_chip = true
		if not on_chip:
			close()
