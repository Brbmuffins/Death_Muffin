class_name DmBugReportView
extends VBoxContainer
## Port of src/ui/BugReportView.ts (Settings -> Report a bug). Like the web it renders INTO the Settings window's body (the window stays open and keeps its
## header and key handling; `DmUiSettings.open_bug_report` swaps the body, Back restores Settings). The form (kind, description 10-2000 chars) sends via
## DmApi.send_bug_report with the context the web attaches, and lists the player's recent reports with the status the bug agent gave them.

signal back_pressed

const CATEGORIES := [["bug", "Something broke"], ["combat", "Combat or thralls"], ["ui", "Menus and interface"], ["performance", "Lag or stutter"], ["balance", "Too hard / too easy"], ["other", "Something else"]]
const MIN_LEN := 10
const MAX_LEN := 2000

var ui: Node
var category: OptionButton
var message: TextEdit
var count_label: Label
var send_button: Button
var back_button: Button
var result_label: Label
var list_box: VBoxContainer
var last_report: Dictionary = {}


func _init() -> void:
	theme = DmUi.theme()
	add_theme_constant_override("separation", 18)   # .cw-settings sections are 18 px apart


static func _section(title_text: String) -> Array:
	var p := PanelContainer.new()
	p.theme_type_variation = "DmInset"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	p.add_child(v)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_bottom", 6)
	m.add_child(DmUi.label(DmUi.upper(title_text), "DmH3"))
	v.add_child(m)
	return [p, v]


func setup(ui_: Node) -> void:
	ui = ui_
	var sec := _section("Report a bug")
	add_child(sec[0])
	var box: VBoxContainer = sec[1]
	var note := DmUi.label("Tell us what went wrong, where you were and what you expected. Your area, level, discipline and game version are attached for you. Reports are read every day.", "DmNote", true)
	note.add_theme_font_size_override("font_size", 14)
	var nm := MarginContainer.new()
	nm.add_theme_constant_override("margin_top", 8)
	nm.add_theme_constant_override("margin_bottom", 2)
	nm.add_child(note)
	box.add_child(nm)
	# label.row: "Kind of problem" + the select, 12 px padding, 1 px rule beneath
	var rm := MarginContainer.new()
	rm.add_theme_constant_override("margin_top", 12)
	rm.add_theme_constant_override("margin_bottom", 12)
	var rh := HBoxContainer.new()
	rh.add_theme_constant_override("separation", 18)
	var rl := DmUi.label("Kind of problem", "DmRow", true)
	rl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rh.add_child(rl)
	category = OptionButton.new()
	for c in CATEGORIES:
		category.add_item(c[1])
	category.size_flags_horizontal = Control.SIZE_SHRINK_END
	rh.add_child(category)
	rm.add_child(rh)
	box.add_child(rm)
	box.add_child(DmUi.hrule())
	message = TextEdit.new()
	message.custom_minimum_size.y = 150   # rows="6"
	message.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	message.placeholder_text = "e.g. After I travelled to the Graves my thralls stopped following me until I relogged."
	message.text_changed.connect(_sync)
	var mm := MarginContainer.new()
	mm.add_theme_constant_override("margin_top", 6)
	mm.add_child(message)
	box.add_child(mm)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	count_label = DmUi.label("0 / %d" % MAX_LEN, "DmHint")
	count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(count_label)
	back_button = Button.new()
	back_button.text = DmUi.upper("Back")
	back_button.focus_mode = Control.FOCUS_NONE
	back_button.pressed.connect(func() -> void: back_pressed.emit())
	row.add_child(back_button)
	send_button = Button.new()
	send_button.text = DmUi.upper("Send report")
	send_button.focus_mode = Control.FOCUS_NONE
	send_button.disabled = true
	send_button.pressed.connect(send)
	row.add_child(send_button)
	var rm2 := MarginContainer.new()
	rm2.add_theme_constant_override("margin_top", 8)
	rm2.add_child(row)
	box.add_child(rm2)
	result_label = DmUi.label("", "DmNote", true)
	result_label.add_theme_font_size_override("font_size", 14)
	box.add_child(result_label)
	var sec2 := _section("Your reports")
	add_child(sec2[0])
	list_box = sec2[1]


## Called when Settings swaps its body for this view: a fresh form and the player's reports.
func show_form() -> void:
	message.text = ""
	result_label.text = ""
	_sync()
	load_list()
	message.grab_focus.call_deferred()


func _sync() -> void:
	if message.text.length() > MAX_LEN:
		message.text = message.text.substr(0, MAX_LEN)
	count_label.text = "%d / %d" % [message.text.length(), MAX_LEN]
	send_button.disabled = message.text.strip_edges().length() < MIN_LEN


func context() -> Dictionary:
	var g: Node = ui.game
	var vp := DisplayServer.window_get_size()
	return {"area": String(g.area_id), "level": int(g.character.get("level", 1)), "discipline": String(ui.build()["discipline"].get("name", "")),
		"release": String(g.get("release") if g.get("release") != null else "unknown"), "coop": String(g.get("party_code") if g.get("party_code") != null else "") != "",
		"viewport": "%dx%d@1" % [vp.x, vp.y], "userAgent": "DeathMuffin Godot %s" % Engine.get_version_info()["string"], "errors": []}


func send() -> void:
	send_button.disabled = true
	result_label.text = "Sending…"
	var cat: String = CATEGORIES[category.selected][0]
	var report := {"category": cat, "message": message.text.strip_edges(), "characterId": int(ui.game.character["id"]), "context": context()}
	last_report = report
	var r: DmResult = await ui.game.api.send_bug_report(report)
	if r.ok:
		message.text = ""
		_sync()
		result_label.text = "Thank you — your report was sent. Check back here for its status."
		load_list()
	else:
		result_label.text = r.error if r.error != "" else "The report could not be sent."
		_sync()


func load_list() -> void:
	for c in list_box.get_children().slice(1):
		c.queue_free()
	var loading := DmUi.label("Loading…", "DmHint")
	list_box.add_child(loading)
	var r: DmResult = await ui.game.api.get_my_bug_reports()
	loading.queue_free()
	if not r.ok or not (r.data is Array):
		list_box.add_child(DmUi.label("Your reports could not be loaded.", "DmHint"))
		return
	if (r.data as Array).is_empty():
		list_box.add_child(DmUi.label("No reports yet.", "DmHint"))
		return
	for rep in r.data:
		var v := VBoxContainer.new()
		var head := DmUi.label("%s · %s" % [rep.get("status", ""), String(rep.get("createdAt", "")).substr(0, 10)], "DmSub")
		v.add_child(head)
		v.add_child(DmUi.label(String(rep.get("message", "")), "DmMuted", true))
		if rep.get("note") != null and String(rep["note"]) != "":
			v.add_child(DmUi.label(String(rep["note"]), "DmNote", true))
		list_box.add_child(v)
