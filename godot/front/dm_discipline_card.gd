class_name DmDisciplineCard
extends PanelContainer
## `.cw-disc`: one discipline card (portrait 3:4, name, epithet, description, passive). Clickable / Enter / Space.

signal chosen(discipline: Dictionary)

var disc: Dictionary
var disabled: bool = false:
	set(v):
		disabled = v
		modulate.a = 0.5 if v else 1.0
var _hover := false
var _color: Color
var _style: StyleBoxFlat


func setup(d: Dictionary, recommended: bool) -> DmDisciplineCard:
	disc = d
	_color = Color(String(d["color"]))
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_style = DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 3, Vector2(0, 0))
	if recommended:
		set_meta("recommended", true)
		_style.border_color = DmUi.BORDER_ACTIVE
	add_theme_stylebox_override("panel", _style)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(v)
	var ar := AspectRatioContainer.new()
	ar.ratio = 0.75
	ar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(ar)
	ar.resized.connect(func():
		var h := ar.size.x / 0.75
		if absf(ar.custom_minimum_size.y - h) > 0.5:
			ar.custom_minimum_size.y = h)
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.clip_contents = true
	ar.add_child(holder)
	var tr := TextureRect.new()
	var tex_path := "res://front/art/" + String(d["portrait"]).trim_prefix("art/")
	tr.texture = load(tex_path) if ResourceLoader.exists(tex_path) else null
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(tr)
	var tag_y := 8.0
	if recommended:
		holder.add_child(_badge("Recommended for your first run", Color("1a1408"), Color("d9b45a"), false, 8.0))
		tag_y = 34.0
	if String(d["family"]) == "necromancer":
		holder.add_child(_badge("Necromancer", DmUi.TEXT_FAINT, Color(0, 0, 0, 0.55), true, tag_y))
	v.add_child(DmUi.hrule(DmUi.BORDER))
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 14)
	m.add_theme_constant_override("margin_right", 14)
	m.add_theme_constant_override("margin_top", 12)
	m.add_theme_constant_override("margin_bottom", 14)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(m)
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", 6)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(b)
	b.add_child(DmFrontUi.lbl(DmUi.upper(String(d["name"])), "display_bold", 22, DmUi.BONE_100, 2.2, true))
	var ep := DmFrontUi.lbl(String(d["epithet"]), "display_italic", 15, _color, 0.0, true)
	b.add_child(ep)
	b.add_child(DmFrontUi.lbl(String(d["description"]), "body", 14, DmUi.TEXT_MUTED, 0.0, true))
	b.add_child(DmUi.hrule(DmUi.BORDER))
	var pr := RichTextLabel.new()
	pr.bbcode_enabled = true
	pr.fit_content = true
	pr.scroll_active = false
	pr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pr.add_theme_font_override("normal_font", DmUi.font("body"))
	pr.add_theme_font_override("bold_font", DmUi.font("body_bold"))
	pr.add_theme_font_size_override("normal_font_size", 13)
	pr.add_theme_font_size_override("bold_font_size", 13)
	pr.add_theme_color_override("default_color", DmUi.BONE_300)
	var passive: Dictionary = d["passive"]
	pr.text = "[b][color=#%s]%s.[/color][/b] %s" % [_color.to_html(false), String(passive["name"]).replace("[", "[lb]"), String(passive["text"]).replace("[", "[lb]")]
	b.add_child(pr)
	mouse_entered.connect(func(): _set_hover(true))
	mouse_exited.connect(func(): _set_hover(false))
	focus_entered.connect(func(): _set_hover(true))
	focus_exited.connect(func(): _set_hover(false))
	return self


func _badge(text: String, fg: Color, bg: Color, right: bool, y: float) -> Control:
	var pc := PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := DmUi.box(bg, Color(0, 0, 0, 0), 1, 0, Vector2(7 if not right else 6, 2))
	pc.add_theme_stylebox_override("panel", sb)
	pc.add_child(DmFrontUi.lbl(DmUi.upper(text), "body_bold", 11, fg, 0.9))
	if right:
		pc.anchor_left = 1.0
		pc.anchor_right = 1.0
		pc.offset_right = -8.0
		pc.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	else:
		pc.offset_left = 8.0
	pc.offset_top = y
	return pc


func _set_hover(h: bool) -> void:
	_hover = h and not disabled
	_style.border_color = _color if _hover else (DmUi.BORDER_ACTIVE if _recommended() else DmUi.BORDER)
	_style.shadow_color = Color(_color, 0.35) if _hover else Color(0, 0, 0, 0)
	_style.shadow_size = 14 if _hover else 0


func _recommended() -> bool:
	return has_meta("recommended")


func _gui_input(e: InputEvent) -> void:
	if disabled:
		return
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		chosen.emit(disc)
		accept_event()
	elif e is InputEventKey and e.pressed and (e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER or e.keycode == KEY_SPACE):
		chosen.emit(disc)
		accept_event()
