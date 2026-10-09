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
var attach_log: CheckBox
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
	var note := DmUi.label("Tell us what went wrong, where you were and what you expected. Your area, level, discipline and game version are attached for you, and your game log if the box below is ticked. Reports are read every day.", "DmNote", true)
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
	# The end of the game log (the crashed session's too, if the game closed on you): owner 2026-10-09, crash reports had to be pasted by hand.
	attach_log = CheckBox.new()
	attach_log.text = "Attach my game log (helps with crashes)"
	attach_log.button_pressed = true
	attach_log.focus_mode = Control.FOCUS_NONE
	var am := MarginContainer.new()
	am.add_theme_constant_override("margin_top", 6)
	am.add_child(attach_log)
	box.add_child(am)
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
	var ctx := context()
	if attach_log.button_pressed:
		var log_text := game_log_tail()
		if log_text != "":
			ctx["log"] = log_text
			ctx["errors"] = log_errors(log_text)
	var report := {"category": cat, "message": message.text.strip_edges(), "characterId": int(ui.game.character["id"]), "context": ctx}
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


## The end of the Godot log: the previous session's (where a crash that closed the game is written) and this one's, newest last,
## at most `max_chars`. The player's home folder becomes ~ and anything that looks like a token or password is blanked.
static func game_log_tail(max_chars: int = 11000, dir: String = "user://logs") -> String:
	var files := DirAccess.get_files_at(dir)
	if files.is_empty():
		return ""
	var previous := ""
	var newest := -1
	for f in files:
		if f.begins_with("godot") and f.ends_with(".log") and f != "godot.log":
			var t := FileAccess.get_modified_time(dir.path_join(f))
			if t > newest:
				newest = t
				previous = f
	var parts: Array[String] = []
	var half := max_chars / 2
	if previous != "":
		parts.append("=== previous session (%s) ===\n%s" % [previous, _tail(FileAccess.get_file_as_string(dir.path_join(previous)), half)])
	if files.has("godot.log"):
		parts.append("=== this session ===\n%s" % _tail(FileAccess.get_file_as_string(dir.path_join("godot.log")), max_chars - half if previous != "" else max_chars))
	return _scrub("\n".join(parts)).right(max_chars)


## Up to five ERROR / SCRIPT ERROR lines from the log, newest last (the report's short "errors" list).
static func log_errors(log_text: String) -> Array:
	var out: Array = []
	for line in log_text.split("\n"):
		if line.contains("ERROR") or line.begins_with("CrashHandlerException"):
			out.append(line.strip_edges().left(400))
	return out.slice(maxi(0, out.size() - 5))


static func _tail(text: String, n: int) -> String:
	return text if text.length() <= n else "…" + text.right(n - 1)


static func _scrub(text: String) -> String:
	for v in ["USERPROFILE", "HOME"]:
		var home := OS.get_environment(v)
		if home.length() > 3:
			text = text.replace(home, "~").replace(home.replace("\\", "/"), "~")
	var kv := RegEx.create_from_string("(?i)(token|authorization|password|secret|api[_-]?key)([\"']?\\s*[:=]\\s*[\"']?)[^\\s,\"'}&]+")
	var bearer := RegEx.create_from_string("(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]+")
	return kv.sub(bearer.sub(text, "$1[redacted]", true), "$1$2[redacted]", true)

