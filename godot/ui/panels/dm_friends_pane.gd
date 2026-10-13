class_name DmFriendsPane
extends VBoxContainer
## The Social window's Friends tab (key O; ui/panels/dm_social_window.gd): add a friend by login name, answer requests, see your friends with the
## class they last played. Pure UI in the ui-kit look: it draws a `view` Dictionary (DmNextFriends.view()) and emits what the player asked for; the
## integrator (game_ui/dm_ui_social.gd) maps the signals to the game.
##
## view: {unavailable: String ("" = usable), loaded: bool, busy: bool, error: String, message: String,
##        friends: [{accountId, username, disciplineIndex, level}], incoming: [{accountId, username}], outgoing: [{accountId, username}]}
## The name field keeps its text while the view changes (it clears after a request went through); rows are rebuilt only when they changed.

signal refresh_requested
signal request_requested(username: String)
signal accept_requested(account_id: int)
signal remove_requested(account_id: int)

const CONFIRM_S := 3.0   ## a Remove button asks "Sure?" this long before it goes back

var view: Dictionary = {}
var name_edit: LineEdit
var add_btn: Button
var unavailable_label: Label
var error_label: Label
var message_label: Label
var main_box: VBoxContainer
var requests_box: VBoxContainer
var requests_rows: VBoxContainer
var friends_head: Label
var friends_rows: VBoxContainer
var empty_label: Label

var _req_sig := 0
var _friends_sig := 0


func _init() -> void:
	add_theme_constant_override("separation", 14)
	unavailable_label = DmUi.label("", "DmNote", true)
	unavailable_label.add_theme_font_size_override("font_size", 15)
	unavailable_label.visible = false
	add_child(unavailable_label)
	main_box = VBoxContainer.new()
	main_box.add_theme_constant_override("separation", 14)
	add_child(main_box)

	var add := _section(main_box, "Add a friend")
	var nr := HBoxContainer.new()
	nr.add_theme_constant_override("separation", 8)
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "The name they log in with"
	name_edit.max_length = 32
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_submitted.connect(func(_t: String) -> void: _on_add())
	nr.add_child(name_edit)
	add_btn = _button("Send request", true)
	add_btn.pressed.connect(_on_add)
	nr.add_child(add_btn)
	add.add_child(nr)
	error_label = DmUi.label("", "DmError", true)
	error_label.add_theme_color_override("font_color", DmUi.DANGER)
	error_label.visible = false
	add.add_child(error_label)
	message_label = DmUi.label("", "DmMuted", true)
	message_label.visible = false
	add.add_child(message_label)
	add.add_child(_note("Friends are mutual: they see your request here and accept it."))

	requests_box = _section(main_box, "Requests")
	requests_rows = VBoxContainer.new()
	requests_rows.add_theme_constant_override("separation", 4)
	requests_box.add_child(requests_rows)

	var fs := _section(main_box, "Friends")
	var fh := HBoxContainer.new()
	friends_head = DmUi.label("", "DmMuted")
	friends_head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fh.add_child(friends_head)
	var rb := _button("Refresh", false)
	rb.pressed.connect(func() -> void: refresh_requested.emit())
	fh.add_child(rb)
	fs.add_child(fh)
	friends_rows = VBoxContainer.new()
	friends_rows.add_theme_constant_override("separation", 4)
	fs.add_child(friends_rows)
	empty_label = DmUi.label("No friends yet. Add someone by the name they log in with.", "DmNote", true)
	empty_label.visible = false
	fs.add_child(empty_label)


## Draw `v`. Cheap when nothing changed.
func set_view(v: Dictionary) -> void:
	var had_message := String(view.get("message", ""))
	view = v
	var why := String(v.get("unavailable", ""))
	unavailable_label.text = why
	unavailable_label.visible = why != ""
	main_box.visible = why == ""
	if why != "":
		return
	var busy := bool(v.get("busy", false))
	add_btn.disabled = busy
	var err := String(v.get("error", ""))
	error_label.text = err
	error_label.visible = err != ""
	var msg := String(v.get("message", ""))
	message_label.text = msg
	message_label.visible = msg != ""
	if msg != "" and msg != had_message:
		name_edit.text = ""   # it went through
	var incoming: Array = v.get("incoming", [])
	var outgoing: Array = v.get("outgoing", [])
	var friends: Array = v.get("friends", [])
	var loaded := bool(v.get("loaded", false))
	(requests_box.get_parent() as Control).visible = not incoming.is_empty() or not outgoing.is_empty()
	friends_head.text = ("%d" % friends.size()) if loaded else ("Loading…" if busy else "")
	empty_label.visible = loaded and friends.is_empty()
	var rs := [incoming, outgoing, busy].hash()
	if rs != _req_sig:
		_req_sig = rs
		_clear(requests_rows)
		for r in incoming:
			requests_rows.add_child(_request_row(r, true, busy))
		for r in outgoing:
			requests_rows.add_child(_request_row(r, false, busy))
	var fsig := [friends, busy].hash()
	if fsig != _friends_sig:
		_friends_sig = fsig
		_clear(friends_rows)
		for f in friends:
			friends_rows.add_child(_friend_row(f, busy))


func _request_row(r: Dictionary, theirs: bool, busy: bool) -> Control:
	var id := int(r.get("accountId", 0))
	var pc := _row(String(r.get("username", "")), "wants to be your friend" if theirs else "waiting for them to accept")
	if theirs:
		var a := _button("Accept", true)
		a.disabled = busy
		a.pressed.connect(func() -> void: accept_requested.emit(id))
		pc.get_child(0).add_child(a)
	var d := _button("Decline" if theirs else "Cancel", false)
	d.disabled = busy
	d.pressed.connect(func() -> void: remove_requested.emit(id))
	pc.get_child(0).add_child(d)
	return pc


func _friend_row(f: Dictionary, busy: bool) -> Control:
	var id := int(f.get("accountId", 0))
	var line := DmNextFriends.class_line(f)
	var pc := _row(String(f.get("username", "")), line if line != "" else "No character yet")
	var b := _button("Remove", false)
	b.disabled = busy
	b.pressed.connect(func() -> void: _confirm_remove(b, id))
	pc.get_child(0).add_child(b)
	return pc


## First press asks, the second (within CONFIRM_S) removes.
func _confirm_remove(b: Button, id: int) -> void:
	if b.has_meta("armed"):
		remove_requested.emit(id)
		return
	b.set_meta("armed", true)
	b.text = DmUi.upper("Sure?")
	get_tree().create_timer(CONFIRM_S).timeout.connect(func() -> void:
		if is_instance_valid(b):
			b.remove_meta("armed")
			b.text = DmUi.upper("Remove"))


func _on_add() -> void:
	if add_btn.disabled:
		return
	request_requested.emit(name_edit.text.strip_edges())


# ---- builders -----------------------------------------------------------------------------------------------------------------------

## An inset row: name over a muted line, buttons appended to the row's HBox (child 0).
func _row(title_text: String, sub_text: String) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.theme_type_variation = "DmInsetTight"
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	pc.add_child(h)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := DmUi.label(title_text, "DmRow")
	nm.clip_text = true
	col.add_child(nm)
	var sub := DmUi.label(sub_text, "DmMuted")
	sub.add_theme_font_size_override("font_size", 13)
	sub.clip_text = true
	col.add_child(sub)
	h.add_child(col)
	return pc


func _clear(box: Container) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


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
