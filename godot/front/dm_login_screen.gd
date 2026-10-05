class_name DmLoginScreen
extends Control
## Port of src/scenes/LoginScene.ts: story column + login / register card over the pyre backdrop.
## `standalone` = the web's VITE_OFFLINE_BUILD (local player name only, no email / password, "Offline edition" wording);
## `dev_offline` = the web's ?offline dev mode (normal fields + "accounts live only in this browser" note).
## Server error strings are shown verbatim, only the first letter capitalised.

signal succeeded(token: String)

var api: DmApi
var standalone: bool = false
var dev_offline: bool = false
var mode: String = "login"   # "login" | "register"

var user_edit: LineEdit
var email_edit: LineEdit
var pass_edit: LineEdit
var submit_btn: Button
var error_label: Label
var toggle_btn: Button
var card: PanelContainer
var kicker_label: Label
var heading_label: Label
var tagline_label: Label

var _busy := false
var _shell: HBoxContainer
var _story: VBoxContainer
var _chapters: Control
var _h1: RichTextLabel
var _card_host: Control


func _init(api_: DmApi = null, standalone_: bool = false, dev_offline_: bool = false) -> void:
	api = api_
	standalone = standalone_
	dev_offline = dev_offline_


func _ready() -> void:
	theme = DmUi.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = DmUi.VOID_950
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	add_child(DmNecroBackdrop.new())
	add_child(DmFrontUi.h_gradient(Color(0.027, 0.024, 0.039, 0.7), Color(0.027, 0.024, 0.039, 0.22), 0.56, Color(0.027, 0.024, 0.039, 0.55)))
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	_shell = HBoxContainer.new()
	_shell.add_theme_constant_override("separation", 72)
	center.add_child(_shell)
	_story = _build_story()
	_shell.add_child(_story)
	_card_host = Control.new()
	_card_host.custom_minimum_size = Vector2(392, 0)
	_card_host.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_shell.add_child(_card_host)
	card = _build_card()
	_card_host.add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.resized.connect(_sync_card_height)
	card.minimum_size_changed.connect(_sync_card_height)
	get_viewport().size_changed.connect(_layout)
	render()
	_layout()


# --- layout ------------------------------------------------------------------------------------

func _layout() -> void:
	var w := size.x if size.x > 0.0 else get_viewport_rect().size.x
	var shell_w := minf(1120.0, w - 56.0)
	var h1_size := int(clampf(w * 0.05, 42.0, 70.0))
	if w <= 560.0:
		h1_size = int(clampf(w * 0.09, 36.0, 45.0))
	_h1.add_theme_font_size_override("normal_font_size", h1_size)
	_h1.add_theme_font_size_override("italics_font_size", h1_size)
	_chapters.visible = w > 560.0
	var stack := w <= 820.0
	_story.visible = true
	_shell.add_theme_constant_override("separation", int(clampf(w * 0.07, 36.0, 104.0)))
	if stack:
		_story.custom_minimum_size.x = 0
		_card_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_shell.custom_minimum_size.x = minf(480.0, w - 36.0)
	else:
		_story.custom_minimum_size.x = maxf(0.0, shell_w - 392.0 - 72.0)
		_card_host.size_flags_horizontal = Control.SIZE_FILL
		_shell.custom_minimum_size.x = shell_w


func _sync_card_height() -> void:
	if card != null:
		_card_host.custom_minimum_size.y = card.get_combined_minimum_size().y


func _build_story() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# logo: sigil circle + two-line wordmark
	var logo := HBoxContainer.new()
	logo.add_theme_constant_override("separation", 12)
	logo.add_child(_Sigil.new())
	logo.add_child(DmFrontUi.lbl("DEATH\nMUFFIN", "display_bold", 34, DmUi.BONE_100, 2.7, false, true))
	v.add_child(logo)
	v.add_child(DmUi.spacer(14))
	var kick := RichTextLabel.new()
	kick.bbcode_enabled = true
	kick.fit_content = true
	kick.scroll_active = false
	kick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	kick.add_theme_font_override("normal_font", DmFrontUi.fv("numeric", 2))
	kick.add_theme_font_size_override("normal_font_size", 12)
	kick.add_theme_color_override("default_color", DmFrontUi.ORANGE)
	kick.text = "THE OSSUARY COVENANT [color=#c6a4ff]  ✦  [/color] THE DIOCESE IS BURNING"
	v.add_child(kick)
	v.add_child(DmUi.spacer(12))
	_h1 = RichTextLabel.new()
	_h1.bbcode_enabled = true
	_h1.fit_content = true
	_h1.scroll_active = false
	_h1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_h1.add_theme_font_override("normal_font", DmFrontUi.fv("display", -1.6))
	_h1.add_theme_font_override("italics_font", DmFrontUi.fv("display_medium", -1.6))
	_h1.add_theme_color_override("default_color", DmUi.BONE_100)
	_h1.text = "The dead don't stay buried.\n[i][color=#f1b481]Neither does the fire.[/color][/i]"
	v.add_child(_h1)
	v.add_child(DmUi.spacer(14))
	var intro := DmFrontUi.lbl("Raise the fallen, face gargoyles and cinderhounds, and carry your legion into the Cinder Pyre.", "body", 20, DmUi.BONE_100, 0.0, true, true)
	intro.custom_minimum_size.x = 300
	v.add_child(intro)
	_chapters = VBoxContainer.new()
	_chapters.add_theme_constant_override("separation", 0)
	var top := DmUi.hrule(Color(0.941, 0.914, 0.863, 0.36))
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 0)
	wrap.add_child(DmUi.spacer(30))
	wrap.add_child(top)
	for row in [["01 / THE GRAVES", "Build your legion from the dead."], ["02 / THE NAVE", "Face deacons, gargoyles, and worse."], ["03 / THE PYRE", "Survive cinderhounds and burning ground."]]:
		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_top", 9)
		m.add_theme_constant_override("margin_bottom", 9)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		var a := DmFrontUi.lbl(row[0], "numeric", 11, DmFrontUi.ORANGE, 1.1)
		a.custom_minimum_size.x = 148
		h.add_child(a)
		h.add_child(DmFrontUi.lbl(row[1], "body_medium", 15, DmUi.BONE_100, 0.0, true, true))
		m.add_child(h)
		wrap.add_child(m)
		wrap.add_child(DmUi.hrule(Color(0.941, 0.914, 0.863, 0.22)))
	_chapters = wrap
	v.add_child(wrap)
	return v


func _build_card() -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "DmPlate"
	# .cw-login background: --cw-engrave over linear-gradient(150deg, rgba(29,20,30,.97), rgba(10,8,14,.98)): painted by DmPlateFill
	var sb := DmUi.box(Color(0, 0, 0, 0), Color(0.941, 0.914, 0.863, 0.35), 1, 3, Vector2(30, 28))
	sb.content_margin_bottom = 25
	sb.shadow_color = Color(0, 0, 0, 0.8)
	sb.shadow_size = 40
	sb.shadow_offset = Vector2(0, 25)
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(DmPlateFill.new())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	p.add_child(v)
	kicker_label = DmFrontUi.lbl("", "numeric", 12, DmFrontUi.ORANGE, 2.2)
	v.add_child(kicker_label)
	v.add_child(DmUi.spacer(7))
	heading_label = DmFrontUi.lbl("", "display", 33, DmUi.BONE_100, 0.0, true)
	v.add_child(heading_label)
	v.add_child(DmUi.spacer(3))
	tagline_label = DmFrontUi.lbl("", "display_italic", 17, DmUi.TEXT_MUTED, 0.0, true)
	v.add_child(tagline_label)
	v.add_child(DmUi.spacer(22))
	var fields := VBoxContainer.new()
	fields.name = "Fields"
	fields.add_theme_constant_override("separation", 14)
	v.add_child(fields)
	v.add_child(DmUi.spacer(14))
	submit_btn = Button.new()
	submit_btn.theme_type_variation = "DmButtonPrimary"
	for state in ["normal", "hover", "pressed"]:
		var s: StyleBox = DmUi.theme().get_stylebox(state, "DmButtonPrimary")
		if s is StyleBoxFlat:
			var c := (s as StyleBoxFlat).duplicate() as StyleBoxFlat
			c.border_color = DmFrontUi.ORANGE_BORDER if state != "hover" else Color("e2ac75")
			c.bg_color = Color(0.2, 0.09, 0.08, 1.0)
			submit_btn.add_theme_stylebox_override(state, c)
	submit_btn.pressed.connect(func(): submit())
	v.add_child(submit_btn)
	error_label = DmFrontUi.lbl("", "body", 14, DmUi.DANGER, 0.0, true)
	error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	error_label.custom_minimum_size.y = 20
	var em := MarginContainer.new()
	em.add_theme_constant_override("margin_top", 8)
	em.add_child(error_label)
	v.add_child(em)
	toggle_btn = Button.new()
	toggle_btn.theme_type_variation = "DmLink"
	toggle_btn.add_theme_font_size_override("font_size", 14)
	toggle_btn.add_theme_color_override("font_color", DmFrontUi.ORANGE)
	toggle_btn.add_theme_color_override("font_hover_color", DmUi.BONE_100)
	toggle_btn.pressed.connect(toggle_mode)
	var tm := MarginContainer.new()
	tm.add_theme_constant_override("margin_top", 14)
	tm.add_child(toggle_btn)
	v.add_child(tm)
	var note := DmFrontUi.lbl("", "body", 12, DmUi.SPELL_300, 0.0, true)
	note.name = "Note"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.modulate.a = 0.8
	var nm := MarginContainer.new()
	nm.add_theme_constant_override("margin_top", 10)
	nm.add_child(note)
	nm.name = "NoteHost"
	v.add_child(nm)
	var corners := DmCorners.new()
	corners.color = DmFrontUi.ORANGE_CORNER
	p.add_child(corners)
	return p


# --- state -------------------------------------------------------------------------------------

func _field(label_text: String, secret: bool, edit_name: String) -> LineEdit:
	var f := VBoxContainer.new()
	f.add_theme_constant_override("separation", 6)
	f.add_child(DmFrontUi.lbl(DmUi.upper(label_text), "display", 13, DmUi.SILVER_400, 2.1))
	var e := LineEdit.new()
	e.name = edit_name
	e.secret = secret
	e.custom_minimum_size.y = 42
	e.text_submitted.connect(func(_t): submit())
	f.add_child(e)
	_fields_box().add_child(f)
	return e


func _fields_box() -> VBoxContainer:
	return card.find_child("Fields", true, false)


## Web render(): rebuilds copy + fields for the current mode.
func render() -> void:
	var is_login := mode == "login"
	for c in _fields_box().get_children():
		c.queue_free()
		_fields_box().remove_child(c)
	if standalone:
		kicker_label.text = "OFFLINE EDITION"
		heading_label.text = "Continue local game" if is_login else "Create local player"
		tagline_label.text = "Your character is saved on this device."
		toggle_btn.text = "Create a local player" if is_login else "Use an existing local player"
		submit_btn.text = DmUi.upper("Continue" if is_login else "Create player")
	else:
		kicker_label.text = "THE GATE IS OPEN" if is_login else "A NEW OATH"
		heading_label.text = "Return to the Covenant" if is_login else "Join the Covenant"
		tagline_label.text = "The dead are waiting to be counted." if is_login else "Your first descent begins here."
		toggle_btn.text = "New to the Covenant? Create an account" if is_login else "Already sworn? Sign in"
		submit_btn.text = DmUi.upper("Descend" if is_login else "Take the Oath")
	user_edit = _field("Local player name" if standalone else "Name", false, "User")
	email_edit = null
	pass_edit = null
	if not is_login and not standalone:
		email_edit = _field("Email", false, "Email")
	if not standalone:
		pass_edit = _field("Password", true, "Pass")
	error_label.text = ""
	var note: Label = card.find_child("Note", true, false)
	var nh: Control = card.find_child("NoteHost", true, false)
	if standalone:
		note.text = "Local players are separate from online accounts. This device stores the save; clearing site data deletes it."
	elif dev_offline:
		note.text = "Offline dev mode — accounts live only in this browser"
	else:
		note.text = ""
	nh.visible = note.text != ""
	_focus_user.call_deferred()
	_sync_card_height.call_deferred()


func _focus_user() -> void:
	if user_edit != null and user_edit.is_inside_tree():
		user_edit.grab_focus()


func toggle_mode() -> void:
	mode = "register" if mode == "login" else "login"
	render()


func fail(message: String) -> void:
	error_label.text = DmFrontUi.capitalize_first(message)
	var x0 := card.position.x
	var tw := create_tween()
	for dx in [-8.0, 7.0, -4.0, 2.0, 0.0]:
		tw.tween_property(card, "position:x", x0 + dx, 0.08)


func _busy_text() -> String:
	if standalone:
		return "Opening…"
	return "Descending…" if mode == "login" else "Swearing…"


## Web submit handler. Returns true when a token was obtained (then `succeeded` is emitted).
func submit() -> bool:
	if _busy:
		return false
	_busy = true
	error_label.text = ""
	submit_btn.disabled = true
	var idle_text := submit_btn.text
	submit_btn.text = DmUi.upper(_busy_text())
	var is_login := mode == "login"
	var name_v := user_edit.text.strip_edges()
	var pass_v := pass_edit.text if pass_edit != null else "local-only"
	var email_v := email_edit.text.strip_edges() if email_edit != null else ""
	var r: DmResult
	if is_login:
		r = await api.login(name_v, pass_v)
	else:
		r = await api.register(name_v, email_v, pass_v)
	_busy = false
	submit_btn.disabled = false
	submit_btn.text = idle_text
	if not r.ok or not (r.data is Dictionary) or not (r.data.get("token") is String):
		fail(r.error if not r.error.is_empty() else "The gate would not open — try again")
		return false
	api.set_token(r.data["token"])
	succeeded.emit(r.data["token"])
	return true


class _Sigil extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(48, 48)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size / 2.0
		draw_circle(c, 23.0, Color(0.608, 0.361, 1.0, 0.13))
		draw_arc(c, 23.5, 0, TAU, 48, Color("b58e6b"), 1.0, true)
		# the web draws the glyph: ✦ (U+2726) in the numeric face at 28 px, #c6a4ff (the bundled symbol face carries it)
		var f: Font = DmUi.font("numeric")
		var gs := f.get_string_size("✦", HORIZONTAL_ALIGNMENT_LEFT, -1, 28)
		draw_string(f, Vector2(c.x - gs.x * 0.5, c.y + 28.0 * 0.32), "✦", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color("c6a4ff"))
