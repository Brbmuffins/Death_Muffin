class_name DmPartyPane
extends VBoxContainer
## The Social window's Party tab (key F; ui/panels/dm_social_window.gd): host an Open or Closed party, join one from the public list, and manage
## the party you are in (Open / Closed, remove players). Friends are invited and asked from the Friends tab. Pure UI in the ui-kit look: it draws a `view` Dictionary (DmNextParty.view()) and emits what the player asked for; the
## integrator (game_ui/dm_ui_social.gd) maps the signals to the game. Nothing here talks to a socket.
##
## view: {unavailable: String ("" = usable), link: off|connecting|ready|failed, mode: solo|host|client|handoff, busy: "listing"|"creating"|"joining"|"",
##        sessions: [{id,name,host,area,players,max,open}], listed: bool, info: {name,host,area,players,max,private,open},
##        error: {code,text}, roster: [{peer_id,name,discipline,host,you,can_kick}], closed: bool, max: int, host_name: String}
## The name field keeps its text while the view changes; only the list and the roster rows are rebuilt, and only when they changed.

signal refresh_requested
signal host_requested(session_name: String, closed: bool)
signal join_requested(session_id: String)
signal leave_requested
signal kick_requested(peer_id: int)
signal closed_toggled(closed: bool)

const CLOSED_TEXT := "Closed: invite only (friends can ask)"
const BUSY_TEXT := {"listing": "Looking for open sessions…", "creating": "Opening your session…", "joining": "Joining…"}
const LINK_TEXT := {"connecting": "Connecting to the lobby…", "failed": "The lobby is unreachable right now.", "off": ""}

var view: Dictionary = {}
var name_edit: LineEdit
var host_closed_check: CheckBox
var host_btn: Button
var error_box: PanelContainer
var error_label: Label
var status_label: Label
var unavailable_label: Label
var solo_box: VBoxContainer
var party_box: VBoxContainer
var list_box: VBoxContainer
var list_head: Label
var roster_box: VBoxContainer
var session_label: Label
var closed_check: CheckBox
var end_btn: Button
var empty_label: Label
var closed_note: Label

var _list_sig := 0
var _roster_sig := 0
var _built := false
var _default_name := ""


func _init() -> void:
	_build_ui()


func _build_ui() -> void:
	add_theme_constant_override("separation", 14)
	# --- messages ---------------------------------------------------------------------------------
	status_label = DmUi.label("", "DmMuted", true)
	status_label.visible = false
	add_child(status_label)
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
	add_child(error_box)
	unavailable_label = DmUi.label("", "DmNote", true)
	unavailable_label.add_theme_font_size_override("font_size", 15)
	unavailable_label.visible = false
	add_child(unavailable_label)

	# --- not in a party: host, the public list ------------------------------------------------------
	solo_box = VBoxContainer.new()
	solo_box.add_theme_constant_override("separation", 14)
	add_child(solo_box)

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
	host_closed_check = CheckBox.new()
	host_closed_check.text = CLOSED_TEXT
	host_closed_check.button_pressed = true
	host_closed_check.focus_mode = Control.FOCUS_NONE
	host.add_child(host_closed_check)
	host.add_child(_note("Closed: only friends you invite (Friends tab) can join, and friends can ask you. Untick for an Open party anyone can join from the list below. You keep playing your own world while others come in (up to 4 players)."))

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
	empty_label = DmUi.label("No open sessions right now. Host one, or join a friend from the Friends tab.", "DmNote", true)
	ls.add_child(empty_label)

	# --- in a party: the session, Open / Closed, the roster -------------------------------------------
	party_box = VBoxContainer.new()
	party_box.add_theme_constant_override("separation", 14)
	party_box.visible = false
	add_child(party_box)
	var ps := _section(party_box, "Your party")
	session_label = DmUi.label("", "DmRow", true)
	ps.add_child(session_label)
	closed_check = CheckBox.new()
	closed_check.text = CLOSED_TEXT
	closed_check.focus_mode = Control.FOCUS_NONE
	closed_check.toggled.connect(func(on: bool) -> void:
		if not _syncing:
			closed_toggled.emit(on))
	ps.add_child(closed_check)
	closed_note = _note("")
	ps.add_child(closed_note)
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
	_syncing = true
	closed_check.visible = is_host
	closed_check.button_pressed = bool(v.get("closed", false))
	_syncing = false
	closed_note.visible = is_host
	if is_host:
		closed_note.text = "Only friends you invite can join; friends can ask. Invite them from the Friends tab." if bool(v.get("closed", false)) \
			else "Open: anyone can see this party in the list and join while there is room."
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
	host_requested.emit(name_edit.text.strip_edges(), host_closed_check.button_pressed)


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
