class_name DmLobbyPanel
extends DmWindow
## Party (the lobby window, key F / the HUD's Party button): host a session, join one from the public list or with a private code, and manage the
## party you are in. Pure UI in the ui-kit look: it draws a `view` Dictionary (DmNextParty.view()) and emits what the player asked for; the
## integrator (game_ui/dm_ui_lobby.gd) maps the signals to the game. Nothing here talks to a socket.
##
## view: {unavailable: String ("" = usable), link: off|connecting|ready|failed, mode: solo|host|client|handoff, busy: "listing"|"creating"|"joining"|"",
##        sessions: [{id,name,host,area,players,max,open}], listed: bool, code: String, info: {name,host,area,players,max,private,open},
##        error: {code,text}, roster: [{peer_id,name,discipline,host,you,can_kick}], open: bool, max: int, host_name: String}
## The two forms (name / code) keep their text while the view changes; only the list and the roster rows are rebuilt, and only when they changed.

signal refresh_requested
signal host_requested(session_name: String, is_private: bool)
signal join_requested(session_id: String)
signal join_code_requested(code: String)
signal leave_requested
signal kick_requested(peer_id: int)
signal open_toggled(open: bool)

const BUSY_TEXT := {"listing": "Looking for open sessions…", "creating": "Opening your session…", "joining": "Joining…"}
const LINK_TEXT := {"connecting": "Connecting to the lobby…", "failed": "The lobby is unreachable right now.", "off": ""}

var view: Dictionary = {}
var name_edit: LineEdit
var public_check: CheckBox
var code_edit: LineEdit
var host_btn: Button
var join_btn: Button
var error_box: PanelContainer
var error_label: Label
var status_label: Label
var unavailable_label: Label
var solo_box: VBoxContainer
var party_box: VBoxContainer
var list_box: VBoxContainer
var list_head: Label
var roster_box: VBoxContainer
var code_big: Label
var copy_btn: Button
var session_label: Label
var open_check: CheckBox
var end_btn: Button
var empty_label: Label
var open_note: Label
var copied_label: Label

var _list_sig := 0
var _roster_sig := 0
var _built := false
var _default_name := ""


func _init() -> void:
	super._init()
	title = "Party"
	aka = "F"
	panel_width = 580
	_build_ui()


func _build_ui() -> void:
	body.add_theme_constant_override("separation", 14)
	# --- messages ---------------------------------------------------------------------------------
	status_label = DmUi.label("", "DmMuted", true)
	status_label.visible = false
	body.add_child(status_label)
	error_box = PanelContainer.new()
	error_box.theme_type_variation = "DmInsetTight"
	var eb := (DmUi.theme().get_stylebox("panel", "DmInsetTight") as StyleBoxFlat).duplicate() as StyleBoxFlat
	eb.border_color = DmUi.DANGER
	eb.set_border_width_all(1)
	eb.content_margin_left = 14
	eb.content_margin_right = 14
	eb.content_margin_top = 9
	eb.content_margin_bottom = 9
	error_box.add_theme_stylebox_override("panel", eb)
	error_label = DmUi.label("", "DmError", true)
	error_label.add_theme_color_override("font_color", DmUi.DANGER)
	error_box.add_child(error_label)
	error_box.visible = false
	body.add_child(error_box)
	unavailable_label = DmUi.label("", "DmNote", true)
	unavailable_label.add_theme_font_size_override("font_size", 15)
	unavailable_label.visible = false
	body.add_child(unavailable_label)

	# --- not in a party: host, join by code, the public list ----------------------------------------
	solo_box = VBoxContainer.new()
	solo_box.add_theme_constant_override("separation", 14)
	body.add_child(solo_box)

	var host := _section(solo_box, "Host a session")
	var nr := HBoxContainer.new()
	nr.add_theme_constant_override("separation", 8)
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Session name"
	name_edit.max_length = DmNextParty.NAME_MAX
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_submitted.connect(func(_t: String) -> void: _on_host())
	nr.add_child(name_edit)
	host_btn = _button("Host session", true)
	host_btn.pressed.connect(_on_host)
	nr.add_child(host_btn)
	host.add_child(nr)
	public_check = CheckBox.new()
	public_check.text = "Show it in the public list (anyone can join)"
	public_check.focus_mode = Control.FOCUS_NONE
	host.add_child(public_check)
	host.add_child(_note("Without the tick it is private: you get a six-digit code to share, and only people with the code can join. You keep playing your own world while friends come in (up to 4 players)."))

	var jc := _section(solo_box, "Join with a code")
	var cr := HBoxContainer.new()
	cr.add_theme_constant_override("separation", 8)
	code_edit = LineEdit.new()
	code_edit.placeholder_text = "Code, e.g. 123456"
	code_edit.max_length = 16
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_code())
	cr.add_child(code_edit)
	join_btn = _button("Join", true)
	join_btn.pressed.connect(_on_join_code)
	cr.add_child(join_btn)
	jc.add_child(cr)

	var ls := _section(solo_box, "Open sessions")
	var lh := HBoxContainer.new()
	list_head = DmUi.label("", "DmMuted")
	list_head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lh.add_child(list_head)
	var rb := _button("Refresh", false)
	rb.pressed.connect(func() -> void: refresh_requested.emit())
	lh.add_child(rb)
	ls.add_child(lh)
	list_box = VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 4)
	ls.add_child(list_box)
	empty_label = DmUi.label("No open sessions right now. Host one, or ask a friend for their code.", "DmNote", true)
	ls.add_child(empty_label)

	# --- in a party: the session, its code, the roster ----------------------------------------------
	party_box = VBoxContainer.new()
	party_box.add_theme_constant_override("separation", 14)
	party_box.visible = false
	body.add_child(party_box)
	var ps := _section(party_box, "Your party")
	session_label = DmUi.label("", "DmRow", true)
	ps.add_child(session_label)
	var cb := HBoxContainer.new()
	cb.add_theme_constant_override("separation", 12)
	var cl := DmUi.label("Code to share", "DmMuted")
	cl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cb.add_child(cl)
	code_big = DmUi.label("", "DmNumeric")
	code_big.add_theme_font_size_override("font_size", 30)
	code_big.add_theme_color_override("font_color", DmUi.GOLD)
	code_big.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_big.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	code_big.mouse_filter = Control.MOUSE_FILTER_PASS
	cb.add_child(code_big)
	copy_btn = _button("Copy code", false)
	copy_btn.pressed.connect(_on_copy)
	cb.add_child(copy_btn)
	cb.set_meta("code_row", true)
	ps.add_child(cb)
	copied_label = DmUi.label("", "DmFaint")
	copied_label.visible = false
	ps.add_child(copied_label)
	open_check = CheckBox.new()
	open_check.text = "Accepting new players"
	open_check.focus_mode = Control.FOCUS_NONE
	open_check.toggled.connect(func(on: bool) -> void:
		if not _syncing:
			open_toggled.emit(on))
	ps.add_child(open_check)
	open_note = _note("")
	ps.add_child(open_note)
	var rs := _section(party_box, "Players")
	roster_box = VBoxContainer.new()
	roster_box.add_theme_constant_override("separation", 4)
	rs.add_child(roster_box)
	end_btn = _button("Leave party", false)
	end_btn.pressed.connect(func() -> void: leave_requested.emit())
	party_box.add_child(end_btn)
	_built = true


var _syncing := false


## Draw `v`. Cheap when nothing changed; only the rows that changed are rebuilt (the typed text in the forms is never touched).
func set_view(v: Dictionary) -> void:
	view = v
	var why := String(v.get("unavailable", ""))
	var mode := String(v.get("mode", "solo"))
	var in_party := mode == "host" or mode == "client"
	unavailable_label.text = why
	unavailable_label.visible = why != ""
	solo_box.visible = why == "" and not in_party
	party_box.visible = why == "" and in_party
	# status line: busy beats the link text
	var busy := String(v.get("busy", ""))
	var st := ""
	if mode == "handoff":
		st = "Joining the session…"
	elif busy != "" and busy != "listing":
		st = String(BUSY_TEXT[busy])
	elif String(v.get("link", "off")) == "connecting":
		st = String(LINK_TEXT["connecting"])
	elif busy == "listing" and not bool(v.get("listed", false)):
		st = String(BUSY_TEXT["listing"])
	status_label.text = st
	status_label.visible = st != "" and why == ""
	var err: Variant = v.get("error", {})
	var et := String((err as Dictionary).get("text", "")) if err is Dictionary else ""
	error_label.text = et
	error_box.visible = et != "" and why == ""
	var idle := busy == "" and mode == "solo"
	host_btn.disabled = not idle
	join_btn.disabled = not idle
	if name_edit.placeholder_text == "Session name" and _default_name != String(v.get("default_name", "")):
		_default_name = String(v.get("default_name", ""))
		if _default_name != "":
			name_edit.placeholder_text = _default_name
	if solo_box.visible:
		_set_list(v.get("sessions", []), bool(v.get("listed", false)), idle)
	if party_box.visible:
		_set_party(v, mode)


func _set_list(sessions: Array, listed: bool, idle: bool) -> void:
	var sig := [sessions, listed, idle].hash()
	if sig == _list_sig:
		return
	_list_sig = sig
	for c in list_box.get_children():
		list_box.remove_child(c)
		c.queue_free()
	list_head.text = ("%d open" % sessions.size()) if listed else ""
	empty_label.visible = listed and sessions.is_empty()
	for s in sessions:
		list_box.add_child(_session_row(s, idle))


func _session_row(s: Dictionary, idle: bool) -> Control:
	var pc := PanelContainer.new()
	pc.theme_type_variation = "DmInsetTight"
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	pc.add_child(h)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := DmUi.label(String(s.get("name", "")), "DmRow")
	nm.clip_text = true
	col.add_child(nm)
	var sub := DmUi.label("%s  ·  %s" % [String(s.get("host", "")), _area_name(String(s.get("area", "")))], "DmMuted")
	sub.add_theme_font_size_override("font_size", 13)
	sub.clip_text = true
	col.add_child(sub)
	h.add_child(col)
	var n := int(s.get("players", 1))
	var mx := int(s.get("max", 4))
	var pl := DmUi.label("%d / %d" % [n, mx], "DmNumeric")
	pl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if n >= mx:
		pl.add_theme_color_override("font_color", DmUi.DANGER)
	h.add_child(pl)
	var b := _button("Full" if n >= mx else "Join", n < mx)
	b.disabled = not idle or n >= mx
	var sid := String(s.get("id", ""))
	b.pressed.connect(func() -> void: join_requested.emit(sid))
	h.add_child(b)
	return pc


static func _area_name(id: String) -> String:
	var a := DmContent.area(id)
	return String(a.get("name", id.capitalize())) if not a.is_empty() else id.replace("_", " ").replace("-", " ").capitalize()


func _set_party(v: Dictionary, mode: String) -> void:
	var info: Dictionary = v.get("info", {})
	var roster: Array = v.get("roster", [])
	var is_host := mode == "host"
	var count := maxi(roster.size(), int(info.get("players", roster.size())))
	var mx := int(v.get("max", 4))
	session_label.text = "%s  ·  %s  ·  %d / %d players" % [String(info.get("name", "Party")), "Hosted by you" if is_host else "Host: %s" % String(v.get("host_name", info.get("host", ""))), count, mx]
	var code := String(v.get("code", ""))
	code_big.text = code
	(code_big.get_parent() as Control).visible = is_host and code != ""
	copied_label.visible = copied_label.visible and is_host and code != ""
	_syncing = true
	open_check.visible = is_host
	open_check.button_pressed = bool(v.get("open", true))
	_syncing = false
	open_note.visible = is_host
	if is_host:
		var public := not bool(info.get("private", true))
		open_note.text = ("Anyone can see this session in the list while it is accepting players. " if public else "Only people with the code can join. ") \
			+ "Untick to keep it as it is: nobody new can come in."
	end_btn.text = DmUi.upper("End session (keep playing solo)" if is_host else "Leave party")
	var sig := [roster, is_host].hash()
	if sig == _roster_sig:
		return
	_roster_sig = sig
	for c in roster_box.get_children():
		roster_box.remove_child(c)
		c.queue_free()
	for r in roster:
		roster_box.add_child(_roster_row(r))


func _roster_row(r: Dictionary) -> Control:
	var pc := PanelContainer.new()
	pc.theme_type_variation = "DmInsetTight"
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	pc.add_child(h)
	var d := DmContent.discipline(String(r.get("discipline", "")))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(DmUi.label(String(r.get("name", "")), "DmRow"))
	var sub := DmUi.label(String(d.get("name", r.get("discipline", ""))), "DmMuted")
	sub.add_theme_font_size_override("font_size", 13)
	col.add_child(sub)
	h.add_child(col)
	if bool(r.get("host", false)):
		h.add_child(_tag("Host", DmUi.GOLD))
	if bool(r.get("you", false)):
		h.add_child(_tag("You", DmUi.SPELL_300))
	if bool(r.get("can_kick", false)):
		var kb := _button("Remove", false)
		var pid := int(r.get("peer_id", 0))
		kb.pressed.connect(func() -> void: kick_requested.emit(pid))
		h.add_child(kb)
	return pc


func _tag(text: String, color: Color) -> Label:
	var l := DmUi.label(DmUi.upper(text), "DmKicker")
	l.add_theme_color_override("font_color", color)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l


# ---- actions ------------------------------------------------------------------------------------------------------------------------

func _on_host() -> void:
	if host_btn.disabled:
		return
	host_requested.emit(name_edit.text.strip_edges(), not public_check.button_pressed)


func _on_join_code() -> void:
	if join_btn.disabled:
		return
	join_code_requested.emit(code_edit.text.strip_edges())


func _on_copy() -> void:
	var code := String(view.get("code", ""))
	if code == "":
		return
	DisplayServer.clipboard_set(code)
	copied_label.text = "Copied. Send it to your friends: they enter it under Join with a code."
	copied_label.visible = true


# ---- builders -----------------------------------------------------------------------------------------------------------------------

func _section(parent: VBoxContainer, title_text: String) -> VBoxContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "DmInset"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	v.add_child(DmUi.label(DmUi.upper(title_text), "DmH3"))
	parent.add_child(p)
	return v


func _button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = DmUi.upper(text)
	b.theme_type_variation = "DmButtonSmallPrimary" if primary else "DmButtonSmall"
	b.focus_mode = Control.FOCUS_NONE
	return b


func _note(text: String) -> Label:
	var l := DmUi.label(text, "DmNote", true)
	l.add_theme_font_size_override("font_size", 14)
	return l
