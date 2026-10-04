extends SceneTree
## Builds res://ui/theme/dm_theme.tres from the web design tokens (src/theme/tokens.css + ui.css + readability.css).
## Run:  godot --headless --path godot --script res://ui/theme/build_theme.gd
## (After the first checkout run `godot --headless --path godot --import` so the font files are imported.)
## The .tres is checked in; only re-run this when tokens change.

const OUT := "res://ui/theme/dm_theme.tres"

var _sys: SystemFont


func _init() -> void:
	_sys = SystemFont.new()
	_sys.font_names = PackedStringArray(["DejaVu Sans", "Noto Sans Symbols 2", "Noto Sans Symbols", "Segoe UI Symbol", "Apple Symbols", "sans-serif"])
	var t := Theme.new()
	t.default_font = _fv("body", 0)
	t.default_font_size = 15

	_labels(t)
	_buttons(t)
	_inputs(t)
	_containers(t)
	_rich(t)
	_misc(t)

	var err := ResourceSaver.save(t, OUT)
	print("dm_theme.tres saved: ", error_string(err))
	quit(0 if err == OK else 1)


# --- fonts -------------------------------------------------------------------------------------
func _fv(kind: String, spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = DmUi.font(kind)
	fv.spacing_glyph = int(round(spacing))
	fv.fallbacks = [_sys]
	return fv


func _var(t: Theme, name: String, base: String, font_kind: String, size: int, color: Color, spacing: float = 0.0) -> void:
	t.set_type_variation(name, base)
	t.set_font("font", name, _fv(font_kind, spacing))
	t.set_font_size("font_size", name, size)
	t.set_color("font_color", name, color)


func _shadowed(t: Theme, name: String, strength: float = 1.0) -> void:
	t.set_color("font_shadow_color", name, Color(0, 0, 0, 0.9 * strength))
	t.set_constant("shadow_offset_x", name, 0)
	t.set_constant("shadow_offset_y", name, 1)


# --- Label variations (web class in comments) ------------------------------------------------------
func _labels(t: Theme) -> void:
	t.set_color("font_color", "Label", DmUi.TEXT)
	# .cw-panel-head .cw-title: Cormorant 600, 24px, .14em, bone-300 (uppercase applied by DmWindow)
	_var(t, "DmTitle", "Label", "display", 24, DmUi.BONE_300, 3.4)
	# .cw-title .aka
	_var(t, "DmAka", "Label", "body", 12, DmUi.TEXT_MUTED, 1.0)
	# .cw-settings-section h3
	_var(t, "DmH3", "Label", "display", 17, DmUi.BONE_100, 1.7)
	# .cw-settings-sub / .cw-keys-h
	_var(t, "DmSub", "Label", "display", 12, DmUi.BONE_300, 1.7)
	# .cw-settings-note (readability: 15px bone-300)
	_var(t, "DmNote", "Label", "body", 15, DmUi.BONE_300)
	_var(t, "DmMuted", "Label", "body", 14, DmUi.TEXT_MUTED)
	_var(t, "DmFaint", "Label", "body", 13, DmUi.TEXT_FAINT)
	_var(t, "DmHint", "Label", "body", 13, DmUi.TEXT_FAINT)
	_var(t, "DmRow", "Label", "body", 15, DmUi.TEXT)
	_var(t, "DmNumeric", "Label", "numeric", 13, DmUi.BONE_100)
	_var(t, "DmGold", "Label", "numeric", 13, DmUi.GOLD)
	# .cw-tip .kicker (readability 12px) / .title / .foot
	_var(t, "DmKicker", "Label", "body_bold", 12, DmUi.SPELL_300, 1.9)
	_var(t, "DmTipTitle", "Label", "display_bold", 18, DmUi.BONE_100, 1.4)
	_var(t, "DmItemName", "Label", "body_bold", 15, DmUi.TEXT)
	_var(t, "DmItemType", "Label", "body", 13, DmUi.TEXT_FAINT)
	_var(t, "DmStat", "Label", "body", 13, DmUi.OK)
	_var(t, "DmLore", "Label", "body_italic", 13, DmUi.TEXT_MUTED)
	_var(t, "DmVerdictUp", "Label", "body_bold", 13, DmUi.UP)
	_var(t, "DmVerdictDown", "Label", "body_bold", 13, DmUi.DOWN)
	_var(t, "DmError", "Label", "body", 14, DmUi.DANGER)
	# .hud-banner .t / .s
	_var(t, "DmBannerTitle", "Label", "display_bold", 44, DmUi.BONE_100, 7.0)
	_shadowed(t, "DmBannerTitle")
	_var(t, "DmBannerSub", "Label", "display_italic", 20, DmUi.BONE_300)
	_shadowed(t, "DmBannerSub")
	# .hud-toast
	_var(t, "DmToastText", "Label", "body", 15, DmUi.BONE_100)
	# floating combat text bases (DmFloatingNumber overrides sizes/colours per kind)
	_var(t, "DmCombatNum", "Label", "numeric", 17, DmUi.BONE_100)
	_shadowed(t, "DmCombatNum")
	# Back to top / tab pips
	_var(t, "DmPip", "Label", "numeric", 9, Color("1a1206"), 0.5)


# --- Buttons -----------------------------------------------------------------------------------
func _btn_styles(t: Theme, type: String, margin: Vector2, primary: bool = false) -> void:
	var bg := DmUi.INSET
	var border := DmUi.BORDER_STRONG
	if primary:
		bg = DmUi.INSET.lerp(Color("9b5cff"), 0.16)
		border = DmUi.SPELL_400.lerp(DmUi.BONE_300, 0.4)
	var normal := DmUi.box(bg, border, 1, 2, margin)
	var hover := DmUi.box(bg.lerp(DmUi.SPELL_400, 0.16), DmUi.BORDER_ACTIVE, 1, 2, margin)
	hover.shadow_color = Color(DmUi.SPELL_400, 0.30)
	hover.shadow_size = 9
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = bg.lerp(DmUi.SPELL_400, 0.26)
	pressed.content_margin_top = margin.y + 1
	pressed.content_margin_bottom = margin.y - 1
	var disabled := DmUi.box(Color(bg, 0.55), Color(border, border.a * 0.45), 1, 2, margin)
	var focus := DmUi.box(Color(0, 0, 0, 0), DmUi.FOCUS, 2, 2, margin)
	t.set_stylebox("normal", type, normal)
	t.set_stylebox("hover", type, hover)
	t.set_stylebox("pressed", type, pressed)
	t.set_stylebox("hover_pressed", type, pressed)
	t.set_stylebox("disabled", type, disabled)
	t.set_stylebox("focus", type, focus)


func _buttons(t: Theme) -> void:
	# .cw-button : Cormorant 600 16px .16em
	_btn_styles(t, "Button", Vector2(14, 8))
	t.set_font("font", "Button", _fv("display", 2.5))
	t.set_font_size("font_size", "Button", 16)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		t.set_color(c, "Button", DmUi.BONE_100)
	t.set_color("font_disabled_color", "Button", Color(DmUi.BONE_100, 0.45))
	t.set_color("icon_normal_color", "Button", DmUi.BONE_100)

	# .cw-button.small : 13px .12em, padding 7/12
	t.set_type_variation("DmButtonSmall", "Button")
	_btn_styles(t, "DmButtonSmall", Vector2(12, 6))
	t.set_font("font", "DmButtonSmall", _fv("display", 1.6))
	t.set_font_size("font_size", "DmButtonSmall", 13)

	# .cw-button.primary
	t.set_type_variation("DmButtonPrimary", "Button")
	_btn_styles(t, "DmButtonPrimary", Vector2(14, 8), true)

	t.set_type_variation("DmButtonSmallPrimary", "DmButtonSmall")
	_btn_styles(t, "DmButtonSmallPrimary", Vector2(12, 6), true)

	# .cw-icon-btn : 40x40, inset, border (the X glyph is drawn by DmIconButton)
	t.set_type_variation("DmIconButton", "Button")
	var ib := DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 2, Vector2(8, 0))
	var ibh := DmUi.box(DmUi.INSET, DmUi.BORDER_ACTIVE, 1, 2, Vector2(8, 0))
	t.set_stylebox("normal", "DmIconButton", ib)
	t.set_stylebox("hover", "DmIconButton", ibh)
	t.set_stylebox("pressed", "DmIconButton", ibh)
	t.set_stylebox("focus", "DmIconButton", DmUi.box(Color(0, 0, 0, 0), DmUi.FOCUS, 2, 2))
	t.set_font_size("font_size", "DmIconButton", 13)

	# .cw-tabs button / .cw-tabwin-tab : inset, border, muted text; .on = bone-100, active border, accent-soft
	t.set_type_variation("DmTab", "Button")
	var tab := DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 0, Vector2(14, 6))
	var tab_on := DmUi.box(DmUi.INSET.lerp(DmUi.SPELL_400, 0.16), DmUi.BORDER_ACTIVE, 1, 0, Vector2(14, 6))
	var tab_hover := DmUi.box(DmUi.INSET, DmUi.BORDER_ACTIVE, 1, 0, Vector2(14, 6))
	t.set_stylebox("normal", "DmTab", tab)
	t.set_stylebox("hover", "DmTab", tab_hover)
	t.set_stylebox("pressed", "DmTab", tab_on)
	t.set_stylebox("hover_pressed", "DmTab", tab_on)
	t.set_stylebox("disabled", "DmTab", tab)
	t.set_stylebox("focus", "DmTab", DmUi.box(Color(0, 0, 0, 0), DmUi.FOCUS, 2, 0))
	t.set_font("font", "DmTab", _fv("display", 1.1))
	t.set_font_size("font_size", "DmTab", 14)
	t.set_color("font_color", "DmTab", DmUi.TEXT_MUTED)
	t.set_color("font_hover_color", "DmTab", DmUi.BONE_100)
	t.set_color("font_pressed_color", "DmTab", DmUi.BONE_100)
	t.set_color("font_hover_pressed_color", "DmTab", DmUi.BONE_100)

	# .cw-back-top button
	t.set_type_variation("DmBackTop", "Button")
	var bt := DmUi.box(DmUi.INSET, DmUi.BORDER_ACTIVE, 1, 0, Vector2(12, 4))
	bt.shadow_color = Color(0, 0, 0, 0.63)
	bt.shadow_size = 6
	bt.shadow_offset = Vector2(0, 2)
	var bth := bt.duplicate() as StyleBoxFlat
	bth.bg_color = DmUi.INSET.lerp(DmUi.SPELL_400, 0.16)
	t.set_stylebox("normal", "DmBackTop", bt)
	t.set_stylebox("hover", "DmBackTop", bth)
	t.set_stylebox("pressed", "DmBackTop", bth)
	t.set_font("font", "DmBackTop", _fv("display", 1.0))
	t.set_font_size("font_size", "DmBackTop", 13)

	# .cw-tip .foot button : plain underlined-ish link text
	t.set_type_variation("DmLink", "Button")
	var none := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "disabled", "focus"]:
		t.set_stylebox(s, "DmLink", none)
	t.set_font("font", "DmLink", _fv("body", 0))
	t.set_font_size("font_size", "DmLink", 12)
	t.set_color("font_color", "DmLink", DmUi.TEXT_MUTED)
	t.set_color("font_hover_color", "DmLink", DmUi.BONE_100)

	# CheckBox: 18px violet-accent box
	var off := _check_icon(false)
	var on := _check_icon(true)
	t.set_icon("unchecked", "CheckBox", off)
	t.set_icon("checked", "CheckBox", on)
	t.set_icon("unchecked_disabled", "CheckBox", off)
	t.set_icon("checked_disabled", "CheckBox", on)
	var cb_empty := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		t.set_stylebox(s, "CheckBox", cb_empty)
	t.set_stylebox("focus", "CheckBox", DmUi.box(Color(0, 0, 0, 0), DmUi.FOCUS, 2, 2))
	t.set_constant("h_separation", "CheckBox", 8)
	t.set_constant("check_v_offset", "CheckBox", 0)
	t.set_font_size("font_size", "CheckBox", 15)
	t.set_color("font_color", "CheckBox", DmUi.TEXT)
	t.set_color("font_hover_color", "CheckBox", DmUi.BONE_100)
	t.set_color("font_pressed_color", "CheckBox", DmUi.BONE_100)
	t.set_color("font_hover_pressed_color", "CheckBox", DmUi.BONE_100)

	# OptionButton : .cw-settings select (min 38px, inset, border, padding 7/10)
	_btn_styles(t, "OptionButton", Vector2(10, 7))
	var o_n := DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 0, Vector2(10, 7))
	var o_h := DmUi.box(DmUi.INSET, DmUi.BORDER_ACTIVE, 1, 0, Vector2(10, 7))
	t.set_stylebox("normal", "OptionButton", o_n)
	t.set_stylebox("hover", "OptionButton", o_h)
	t.set_stylebox("pressed", "OptionButton", o_h)
	t.set_stylebox("hover_pressed", "OptionButton", o_h)
	t.set_stylebox("disabled", "OptionButton", DmUi.box(Color(DmUi.INSET, 0.6), Color(DmUi.BORDER, 0.1), 1, 0, Vector2(10, 7)))
	t.set_font("font", "OptionButton", _fv("body", 0))
	t.set_font_size("font_size", "OptionButton", 15)
	t.set_icon("arrow", "OptionButton", _arrow_icon())
	t.set_constant("arrow_margin", "OptionButton", 8)
	t.set_constant("h_separation", "OptionButton", 8)
	t.set_color("font_color", "OptionButton", DmUi.TEXT)
	t.set_color("font_hover_color", "OptionButton", DmUi.BONE_100)
	t.set_color("font_pressed_color", "OptionButton", DmUi.BONE_100)
	t.set_color("font_hover_pressed_color", "OptionButton", DmUi.BONE_100)
	t.set_color("font_focus_color", "OptionButton", DmUi.TEXT)
	t.set_color("font_disabled_color", "OptionButton", Color(DmUi.TEXT, 0.5))
	t.set_stylebox("focus", "OptionButton", DmUi.box(Color(0, 0, 0, 0), DmUi.FOCUS, 2, 0))

	# PopupMenu (the option list)
	var pm := DmUi.box(Color("0b090f"), DmUi.BORDER_STRONG, 1, 0, Vector2(2, 2))
	t.set_stylebox("panel", "PopupMenu", pm)
	t.set_stylebox("hover", "PopupMenu", DmUi.box(DmUi.ACCENT_SOFT, Color(0, 0, 0, 0), 0, 0))
	t.set_stylebox("separator", "PopupMenu", DmUi.box(DmUi.BORDER, Color(0, 0, 0, 0), 0, 0))
	t.set_font("font", "PopupMenu", _fv("body", 0))
	t.set_font_size("font_size", "PopupMenu", 15)
	t.set_color("font_color", "PopupMenu", DmUi.TEXT)
	t.set_color("font_hover_color", "PopupMenu", DmUi.BONE_100)
	t.set_color("font_disabled_color", "PopupMenu", DmUi.TEXT_FAINT)
	t.set_constant("v_separation", "PopupMenu", 6)
	t.set_constant("item_start_padding", "PopupMenu", 8)
	t.set_constant("item_end_padding", "PopupMenu", 8)
	t.set_icon("radio_checked", "PopupMenu", _dot_icon(true))
	t.set_icon("radio_unchecked", "PopupMenu", _dot_icon(false))


# --- Inputs: sliders, line edit, scrollbars ---------------------------------------------------------
func _inputs(t: Theme) -> void:
	# input[type=range]: thin inset track, violet fill, violet round thumb
	var track := DmUi.box(Color("1a1422"), Color(DmUi.BONE_300, 0.16), 1, 3)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := DmUi.box(DmUi.SPELL_400, Color(0, 0, 0, 0), 0, 3)
	fill.content_margin_top = 3
	fill.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	var grab := _knob_icon(false)
	var grab_h := _knob_icon(true)
	t.set_icon("grabber", "HSlider", grab)
	t.set_icon("grabber_highlight", "HSlider", grab_h)
	t.set_icon("grabber_disabled", "HSlider", grab)
	t.set_constant("center_grabber", "HSlider", 0)

	# .cw-field input / party-code input
	var le := DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 2, Vector2(12, 9))
	var le_f := DmUi.box(DmUi.INSET, DmUi.FOCUS, 1, 2, Vector2(12, 9))
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", le_f)
	t.set_stylebox("read_only", "LineEdit", le)
	t.set_font("font", "LineEdit", _fv("body", 0))
	t.set_font_size("font_size", "LineEdit", 15)
	t.set_color("font_color", "LineEdit", DmUi.TEXT)
	t.set_color("font_placeholder_color", "LineEdit", DmUi.TEXT_MUTED)
	t.set_color("caret_color", "LineEdit", DmUi.SPELL_300)
	t.set_color("selection_color", "LineEdit", Color(DmUi.SPELL_400, 0.4))

	# Scroll bars: thin bone-tinted thumbs
	for kind in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", kind, DmUi.box(Color(0, 0, 0, 0.35), Color(0, 0, 0, 0), 0, 3))
		t.set_stylebox("scroll_focus", kind, DmUi.box(Color(0, 0, 0, 0.35), Color(0, 0, 0, 0), 0, 3))
		t.set_stylebox("grabber", kind, DmUi.box(Color(DmUi.BONE_300, 0.30), Color(0, 0, 0, 0), 0, 3))
		t.set_stylebox("grabber_highlight", kind, DmUi.box(Color(DmUi.BONE_300, 0.50), Color(0, 0, 0, 0), 0, 3))
		t.set_stylebox("grabber_pressed", kind, DmUi.box(Color(DmUi.SPELL_300, 0.65), Color(0, 0, 0, 0), 0, 3))
	t.set_constant("scrollbar_margin_right", "VScrollBar", 0)
	for kind in ["VScrollBar", "HScrollBar"]:
		for ic in ["increment", "decrement", "increment_highlight", "decrement_highlight", "increment_pressed", "decrement_pressed"]:
			t.set_icon(ic, kind, _blank_icon())

	t.set_stylebox("separator", "HSeparator", DmUi.box(DmUi.BORDER, Color(0, 0, 0, 0), 0, 0))
	t.set_constant("separation", "HSeparator", 1)
	t.set_stylebox("separator", "VSeparator", DmUi.box(DmUi.BORDER, Color(0, 0, 0, 0), 0, 0))
	t.set_constant("separation", "VSeparator", 1)

	# ProgressBar (profession/contract bars): 6px inset with violet fill
	t.set_stylebox("background", "ProgressBar", DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 0))
	t.set_stylebox("fill", "ProgressBar", DmUi.box(DmUi.SPELL_400, Color(0, 0, 0, 0), 0, 0))
	t.set_font_size("font_size", "ProgressBar", 11)


# --- Containers ----------------------------------------------------------------------------------
func _containers(t: Theme) -> void:
	# .cw-plate (panel): bg panel, 1px border, 3px radius, deep shadow. Corner brackets are drawn by DmWindow / DmPlate.
	var plate := DmUi.box(DmUi.PANEL, DmUi.BORDER, 1, 3, Vector2(22, 20))
	plate.shadow_color = DmUi.PANEL_SHADOW
	plate.shadow_size = 30
	plate.shadow_offset = Vector2(0, 14)
	t.set_type_variation("DmPlate", "PanelContainer")
	t.set_stylebox("panel", "DmPlate", plate)
	# .cw-settings-section / .cw-settings-top / .cw-bag-detail : inset boxes
	t.set_type_variation("DmInset", "PanelContainer")
	t.set_stylebox("panel", "DmInset", DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 0, Vector2(16, 14)))
	t.set_type_variation("DmInsetTight", "PanelContainer")
	t.set_stylebox("panel", "DmInsetTight", DmUi.box(DmUi.INSET, DmUi.BORDER, 1, 0, Vector2(12, 8)))
	# .cw-tip : counsel card (plate, tighter padding)
	t.set_type_variation("DmTipPlate", "PanelContainer")
	var tip := DmUi.box(DmUi.PANEL, DmUi.BORDER, 1, 3, Vector2(14, 10))
	tip.shadow_color = DmUi.PANEL_SHADOW
	tip.shadow_size = 24
	tip.shadow_offset = Vector2(0, 10)
	t.set_stylebox("panel", "DmTipPlate", tip)
	# .hud-toast
	t.set_type_variation("DmToast", "PanelContainer")
	t.set_stylebox("panel", "DmToast", DmUi.box(Color(0.0275, 0.0235, 0.0392, 0.9), DmUi.BORDER_STRONG, 1, 0, Vector2(16, 8)))
	t.set_type_variation("DmToastGood", "DmToast")
	t.set_stylebox("panel", "DmToastGood", DmUi.box(Color(0.0275, 0.0235, 0.0392, 0.9), Color(DmUi.SPELL_400, 0.70), 1, 0, Vector2(16, 8)))
	t.set_type_variation("DmToastErr", "DmToast")
	t.set_stylebox("panel", "DmToastErr", DmUi.box(Color(0.0275, 0.0235, 0.0392, 0.9), Color(DmUi.DANGER, 0.60), 1, 0, Vector2(16, 8)))
	t.set_type_variation("DmToastMajor", "DmToast")
	t.set_stylebox("panel", "DmToastMajor", DmUi.box(Color(0.0275, 0.0235, 0.0392, 0.9), DmUi.GOLD, 1, 0, Vector2(16, 8)))
	# .cw-tooltip (item tooltip card)
	t.set_type_variation("DmTooltipCard", "PanelContainer")
	t.set_stylebox("panel", "DmTooltipCard", DmUi.box(Color(0.0275, 0.0235, 0.0392, 0.97), DmUi.BORDER_STRONG, 1, 0, Vector2(12, 10)))
	# Godot's own plain-text tooltips
	t.set_stylebox("panel", "TooltipPanel", DmUi.box(Color(0.0275, 0.0235, 0.0392, 0.97), DmUi.BORDER_STRONG, 1, 0, Vector2(10, 7)))
	t.set_font("font", "TooltipLabel", _fv("body", 0))
	t.set_font_size("font_size", "TooltipLabel", 13)
	t.set_color("font_color", "TooltipLabel", DmUi.TEXT)
	# slots' backing when a plain PanelContainer is wanted
	t.set_constant("separation", "VBoxContainer", 6)
	t.set_constant("separation", "HBoxContainer", 8)


func _rich(t: Theme) -> void:
	t.set_font("normal_font", "RichTextLabel", _fv("body", 0))
	t.set_font("bold_font", "RichTextLabel", _fv("body_bold", 0))
	t.set_font("italics_font", "RichTextLabel", _fv("body_italic", 0))
	t.set_font("bold_italics_font", "RichTextLabel", _fv("body_bold", 0))
	t.set_font("mono_font", "RichTextLabel", _fv("numeric", 0))
	t.set_font_size("normal_font_size", "RichTextLabel", 15)
	t.set_font_size("bold_font_size", "RichTextLabel", 15)
	t.set_font_size("italics_font_size", "RichTextLabel", 15)
	t.set_font_size("bold_italics_font_size", "RichTextLabel", 15)
	t.set_font_size("mono_font_size", "RichTextLabel", 13)
	t.set_color("default_color", "RichTextLabel", DmUi.BONE_300)
	t.set_constant("line_separation", "RichTextLabel", 2)
	t.set_type_variation("DmRichTip", "RichTextLabel")
	t.set_font_size("normal_font_size", "DmRichTip", 14)
	t.set_font_size("bold_font_size", "DmRichTip", 14)
	t.set_font_size("italics_font_size", "DmRichTip", 14)
	t.set_constant("line_separation", "DmRichTip", 3)


func _misc(t: Theme) -> void:
	t.set_stylebox("focus", "Control", DmUi.box(Color(0, 0, 0, 0), DmUi.FOCUS, 2, 2))


# --- procedural icons (supersampled so edges are smooth) -----------------------------------------------
func _img(w: int, h: int) -> Image:
	var im := Image.create(w, h, false, Image.FORMAT_RGBA8)
	im.fill(Color(0, 0, 0, 0))
	return im


func _blank_icon() -> Texture2D:
	return ImageTexture.create_from_image(_img(1, 1))


func _cover(px: float, py: float, inside: Callable) -> float:
	# 4x4 supersample coverage of a pixel
	var n := 0
	for sy in 4:
		for sx in 4:
			if inside.call(px + (sx + 0.5) / 4.0, py + (sy + 0.5) / 4.0):
				n += 1
	return n / 16.0


func _check_icon(checked: bool) -> Texture2D:
	var S := 18
	var im := _img(S, S)
	var border := Color(DmUi.BONE_300, 0.55) if not checked else DmUi.SPELL_400
	var fill := Color("1a1422") if not checked else DmUi.SPELL_400
	for y in S:
		for x in S:
			var inside_rr := func(fx: float, fy: float) -> bool:
				return fx >= 0.5 and fx <= S - 0.5 and fy >= 0.5 and fy <= S - 0.5
			var core := func(fx: float, fy: float) -> bool:
				return fx >= 2.0 and fx <= S - 2.0 and fy >= 2.0 and fy <= S - 2.0
			var a_out := _cover(x, y, inside_rr)
			var a_in := _cover(x, y, core)
			var c := Color(0, 0, 0, 0)
			if a_out > 0.0:
				c = Color(border, border.a * a_out)
				if a_in > 0.0:
					c = c.lerp(fill, a_in)
					c.a = maxf(c.a, a_out * fill.a)
			im.set_pixel(x, y, c)
	if checked:
		# white tick: two segments (4,9)->(7.5,12.5)->(14,5.5)
		var segs := [[Vector2(4.2, 9.2), Vector2(7.6, 12.6)], [Vector2(7.6, 12.6), Vector2(13.8, 5.6)]]
		for y in S:
			for x in S:
				var a := _cover(x, y, func(fx: float, fy: float) -> bool:
					for sg in segs:
						if _dist_seg(Vector2(fx, fy), sg[0], sg[1]) <= 1.1:
							return true
					return false)
				if a > 0.0:
					var base := im.get_pixel(x, y)
					im.set_pixel(x, y, base.lerp(Color(1, 1, 1, 1), a))
	return ImageTexture.create_from_image(im)


func _dist_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _arrow_icon() -> Texture2D:
	var im := _img(11, 7)
	var tri := PackedVector2Array([Vector2(0.5, 0.8), Vector2(10.5, 0.8), Vector2(5.5, 6.2)])
	for y in 7:
		for x in 11:
			var a := _cover(x, y, func(fx: float, fy: float) -> bool: return Geometry2D.is_point_in_polygon(Vector2(fx, fy), tri))
			if a > 0.0:
				im.set_pixel(x, y, Color(DmUi.BONE_300, a))
	return ImageTexture.create_from_image(im)


func _dot_icon(on: bool) -> Texture2D:
	var im := _img(10, 10)
	if on:
		for y in 10:
			for x in 10:
				var a := _cover(x, y, func(fx: float, fy: float) -> bool: return Vector2(fx, fy).distance_to(Vector2(5, 5)) <= 3.0)
				if a > 0.0:
					im.set_pixel(x, y, Color(DmUi.SPELL_300, a))
	return ImageTexture.create_from_image(im)


func _knob_icon(hot: bool) -> Texture2D:
	var S := 16
	var im := _img(S, S)
	var col := DmUi.SPELL_300 if hot else DmUi.SPELL_400
	for y in S:
		for x in S:
			var a := _cover(x, y, func(fx: float, fy: float) -> bool: return Vector2(fx, fy).distance_to(Vector2(8, 8)) <= 7.0)
			var a2 := _cover(x, y, func(fx: float, fy: float) -> bool: return Vector2(fx, fy).distance_to(Vector2(8, 8)) <= 5.4)
			if a > 0.0:
				var c := Color(DmUi.BONE_100, 0.85 * a).lerp(Color(col, 1.0), a2)
				c.a = a
				im.set_pixel(x, y, c)
	return ImageTexture.create_from_image(im)
