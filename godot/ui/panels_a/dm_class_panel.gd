class_name DmClassPanel
extends DmWindow
## Change class (src/ui/ClassPanel.ts): the same portraits and cards as initial class selection, nine playable disciplines, free to change.
## Data in:  set_data(current_class_index: int, disciplines: Array = [])  (default: the exported PLAYABLE_DISCIPLINES)
## Signals:  class_chosen(class_index)  -> DmApi.change_discipline(character_id, class_index); on success the client reloads into the Chapterhouse.
## While a change is in flight call begin_saving(); on a refusal call fail(message) (verbatim server error); on done call finish().

signal class_chosen(class_index: int)

var current := 0
var disciplines: Array = []
var busy := false
var status := ""
var error := ""
var _status_label: Label
var _error_label: Label
var _cards: Array = []


func _init() -> void:
	super._init()
	title = "Change class"
	panel_width = 1000
	top_gap = 20


func set_data(current_class_index: int, list: Array = []) -> void:
	current = current_class_index
	disciplines = list if not list.is_empty() else DmContent.file("disciplines").get("PLAYABLE_DISCIPLINES", [])
	render()


func render() -> void:
	DmPa.clear(body)
	_cards.clear()
	body.add_child(DmPa.text("Change class whenever you want, at no cost. Your level, gold, items, upgrades and progress stay with this character. Changing class returns you to the Chapterhouse.", 14, DmUi.TEXT_MUTED))
	var g := DmPa.grid(4, 14, 14)
	for d in disciplines:
		g.add_child(_card(d))
	body.add_child(g)
	_status_label = DmPa.text(status, 14, DmUi.TEXT_MUTED)
	_status_label.set_meta("role", "status")
	body.add_child(_status_label)
	_error_label = DmPa.text(error, 14, DmUi.DANGER)
	_error_label.set_meta("role", "error")
	body.add_child(_error_label)


func _card(d: Dictionary) -> Control:
	var idx := int(d["classIndex"])
	var is_current := idx == current
	var col := Color(String(d["color"]))
	var c := PanelContainer.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_theme_stylebox_override("panel", DmUi.box(DmUi.INSET, col if is_current else DmUi.BORDER, 1, 0, Vector2(0, 0)))
	c.set_meta("act", "class")
	c.set_meta("arg", idx)
	c.set_meta("disabled", is_current or busy)
	c.set_meta("current", is_current)
	c.mouse_default_cursor_shape = Control.CURSOR_ARROW if (is_current or busy) else Control.CURSOR_POINTING_HAND
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	c.add_child(v)
	var ph := DmPaPortrait.new()
	ph.setup(String(d.get("portrait", "")), String(d["id"]), col)
	v.add_child(ph)
	v.add_child(DmPa.hrule())
	var b := DmPa.vbox(6)
	v.add_child(DmPa.margin(b, 14, 12, 14, 14))
	b.add_child(DmPa.text(DmUi.upper(String(d["name"])), 22, DmUi.BONE_100, "display_bold", false))
	b.add_child(DmPa.text(String(d["epithet"]), 15, col, "display_italic", true))
	b.add_child(DmPa.text(String(d["description"]), 14, DmUi.TEXT_MUTED))
	b.add_child(DmPa.hrule())
	var p: Dictionary = d["passive"]
	b.add_child(DmPa.rich("<b>%s.</b> %s" % [p["name"], p["text"]], 13, DmUi.BONE_300))
	if is_current:
		b.add_child(DmPa.text("Current class", 13, DmUi.BONE_300))
	c.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and not (is_current or busy):
			choose(idx))
	c.modulate = Color(1, 1, 1, 0.5) if busy and not is_current else Color(1, 1, 1, 1)
	_cards.append(c)
	return c


## What a click does (also callable from tests): ignored for the current class or while busy.
func choose(idx: int) -> void:
	if busy or idx == current:
		return
	class_chosen.emit(idx)


func begin_saving() -> void:
	busy = true
	error = ""
	status = "Saving your character and changing class…"
	render()


func fail(message: String) -> void:
	busy = false
	status = ""
	error = message if message != "" else "Could not change class. Please try again."
	render()


func finish() -> void:
	busy = false
	status = ""
	render()


## The web ignores Esc/close while a change is saving.
func close() -> void:
	if not busy:
		super.close()
