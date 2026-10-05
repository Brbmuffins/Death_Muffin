class_name DmBugReportView
extends DmWindow
## Port of src/ui/BugReportView.ts (Settings -> Report a bug): the form (kind, description 10-2000 chars), sends via DmApi.send_bug_report with the
## context the web attaches, and lists the player's recent reports with the status the bug agent gave them.

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
	super._init()
	title = "Report a bug"
	panel_width = 540


func setup(ui_: Node) -> void:
	ui = ui_
	var note := DmUi.label("Tell us what went wrong, where you were and what you expected. Your area, level, discipline and game version are attached for you. Reports are read every day.", "DmNote", true)
	body.add_child(note)
	category = OptionButton.new()
	for c in CATEGORIES:
		category.add_item(c[1])
	body.add_child(category)
	message = TextEdit.new()
	message.custom_minimum_size.y = 120
	message.placeholder_text = "e.g. After I travelled to the Graves my thralls stopped following me until I relogged."
	message.text_changed.connect(_sync)
	body.add_child(message)
	var row := HBoxContainer.new()
	count_label = DmUi.label("0 / %d" % MAX_LEN, "DmHint")
	count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(count_label)
	back_button = Button.new()
	back_button.text = DmUi.upper("Back")
	back_button.pressed.connect(func() -> void:
		close()
		back_pressed.emit())
	row.add_child(back_button)
	send_button = Button.new()
	send_button.text = DmUi.upper("Send report")
	send_button.disabled = true
	send_button.pressed.connect(send)
	row.add_child(send_button)
	body.add_child(row)
	result_label = DmUi.label("", "DmNote", true)
	body.add_child(result_label)
	body.add_child(DmUi.label(DmUi.upper("Your reports"), "DmSub"))
	list_box = VBoxContainer.new()
	body.add_child(list_box)
	opened.connect(func() -> void: load_list())


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
	for c in list_box.get_children():
		c.queue_free()
	var r: DmResult = await ui.game.api.get_my_bug_reports()
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
