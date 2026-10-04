class_name DmDialoguePanel
extends PanelContainer
## The conversation card (src/ui/DialoguePanel.ts). Non-modal: sits high on the screen, never pauses the game, closes by Esc, the X, Goodbye,
## pressing E again, or walking away (the world checks the distance and calls close()). Two to four buttons at a time.
##
## Text and heard-state come from a `source` (DmDialogueSource): in the game that is the port of content/dialogue.ts + gameplay/guidance.ts,
## which is NOT part of this track; DmDialogueSource ships with the static strings (labels, menu lines) and stub lines so the panel is complete.
## Signals: npc_changed(npc_id or "") -> the camera/world (talkingTo); sound() -> the UI click.

signal npc_changed(npc_id: String)
signal sound

const WIDTH := 560.0
## Node kinds: greet, advice, menu, about, bye, topic.
var npc := ""
var node_kind := "greet"
var topic_id := ""
var lines: Array = []
var source: DmDialogueSource = DmDialogueSource.new()

var _name_label: Label
var _title_label: Label
var _say: VBoxContainer
var _choices_box: VBoxContainer
var _choices: Array = []
var _accent := DmUi.SPELL_400


func _init() -> void:
	theme = DmUi.theme()
	theme_type_variation = "DmPlate"
	custom_minimum_size.x = WIDTH
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := (DmUi.theme().get_stylebox("panel", "DmPlate").duplicate() as StyleBoxFlat)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 14
	sb.content_margin_bottom = 16
	sb.border_width_top = 2
	add_theme_stylebox_override("panel", sb)
	var v := DmPa.vbox(8)
	add_child(v)
	var hd := DmPa.hbox(12)
	v.add_child(hd)
	var names := DmPa.vbox(0)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label = DmPa.text("", 22, DmUi.BONE_100, "display_bold", false)
	names.add_child(_name_label)
	_title_label = DmPa.text("", 13, DmUi.SPELL_300, "body", false)
	names.add_child(_title_label)
	hd.add_child(names)
	var x := DmIconButton.new()
	x.tooltip_text = "End conversation (Esc)"
	x.set_meta("act", "close")
	x.pressed.connect(func() -> void:
		sound.emit()
		close())
	hd.add_child(x)
	_say = DmPa.vbox(8)
	v.add_child(_say)
	_choices_box = DmPa.vbox(6)
	v.add_child(_choices_box)


func is_open() -> bool:
	return visible


func open_npc(id: String) -> void:
	if npc == id and visible:
		return
	close()
	npc = id
	var def: Dictionary = DmContent.get_export("npcs", "NPCS").get(id, {})
	_accent = Color.from_rgba8((int(def.get("accent", 0)) >> 16) & 255, (int(def.get("accent", 0)) >> 8) & 255, int(def.get("accent", 0)) & 255)
	var sb := get_theme_stylebox("panel") as StyleBoxFlat
	sb.border_color = _accent
	_title_label.add_theme_color_override("font_color", _accent)
	_name_label.text = DmUi.upper(String(def.get("name", id)))
	_title_label.text = String(def.get("title", ""))
	lines = source.greeting_lines(id)
	source.told(id)
	node_kind = "greet"
	visible = true
	npc_changed.emit(id)
	render()


func close() -> void:
	if not visible:
		return
	visible = false
	npc = ""
	npc_changed.emit("")


## Refresh the words after the world changed under an open conversation.
func refresh() -> void:
	if visible and node_kind != "greet":
		go(node_kind, topic_id)


func go(kind: String, id: String = "") -> void:
	if npc == "":
		return
	node_kind = kind
	topic_id = id
	match kind:
		"advice":
			lines = source.advice_lines(npc)
		"menu":
			lines = [String({"prior": "Ask, and I will answer as plainly as I can.", "sexton": "Go on, then. I have all the time the dead do.", "apothecary": "Quickly, before something boils over."}[npc])]
		"about":
			lines = ["What shall I tell you of?"]
		"topic":
			lines = source.topic_lines(npc, id)
			source.hear_topic(npc, id)
		"bye":
			lines = [source.farewell(npc)]
	render()


## The buttons for the current node: [{label, fresh, act}] (act is the node to go to, or "close").
func choices() -> Array:
	var labels: Dictionary = DmContent.get_export("dialogue", "LABEL")
	var advice := {"label": String(labels["advice"][npc]), "go": "advice"}
	var about := {"label": String(labels["about"]), "go": "about"}
	var bye := {"label": String(labels["bye"]), "go": "close"}
	match node_kind:
		"greet", "menu":
			return [advice, about, bye]
		"advice":
			return [about, bye]
		"about":
			var out: Array = []
			for t in DmContent.get_export("dialogue", "TOPICS")[npc]:
				out.append({"label": String(t["label"]), "fresh": not source.heard_topic(npc, String(t["id"])), "go": "topic", "id": String(t["id"])})
			out.append({"label": String(labels["back"]), "go": "menu"})
			return out
		"topic":
			return [advice, {"label": "Tell me of something else", "go": "about"}, bye]
	return [bye]


func render() -> void:
	if npc == "":
		return
	DmPa.clear(_say)
	for l in lines:
		_say.add_child(DmPa.text(String(l), 15, DmUi.BONE_300))
	DmPa.clear(_choices_box)
	_choices = choices()
	for i in _choices.size():
		var c: Dictionary = _choices[i]
		var b := Button.new()
		b.text = String(c["label"])
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.set_meta("act", "choice")
		b.set_meta("arg", i)
		b.set_meta("fresh", bool(c.get("fresh", false)))
		b.theme_type_variation = "DmButtonSmall"
		b.pressed.connect(choose.bind(i))
		if bool(c.get("fresh", false)):
			b.add_child(_fresh_dot())
		_choices_box.add_child(b)


func _fresh_dot() -> Control:
	var d := ColorRect.new()
	d.color = DmUi.GOLD
	d.custom_minimum_size = Vector2(6, 6)
	d.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	d.offset_left = -16
	d.offset_right = -10
	d.offset_top = -3
	d.offset_bottom = 3
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return d


func choose(i: int) -> void:
	if i < 0 or i >= _choices.size():
		return
	sound.emit()
	var c: Dictionary = _choices[i]
	if c["go"] == "close":
		close()
	else:
		go(String(c["go"]), String(c.get("id", "")))


func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
