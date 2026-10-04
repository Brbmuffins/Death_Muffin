class_name DmSheetView
extends VBoxContainer
## The Character sheet (Sheet · J; src/ui/CharacterSheet.ts): "What you're looking for", then every stat as a line that expands into its breakdown
## (base, level, each worn item, discipline, tiers, boons). Set-bonus and affix lines are always open. Pure display of gearStats.statSheet()/lookingFor().
##
## Data in:  set_data({ready: bool, primer, looking: {discipline, orderText, why, weapons, weakest:[{text, empty}]},
##           sections:[{id, title, lines:[{id, label, value, help, rows:[{label, value, tone?, total?}]}]}]})
##           (godot/data/panels_a/sheet_sample.json is a real sample). Whoever ports gameplay/gearStats.ts produces this dictionary.
## Signals:  line_toggled(id, open)   (no DmApi call; first open of the sheet raises the "statSheet" counsel tip in the web: `opened` on the window)

signal line_toggled(id: String, open: bool)

const LBL_W := 120
const VAL_W := 90
const RED := Color("d97a6b")

var data: Dictionary = {}
var open_lines: Dictionary = {"maxHp": true}


func _init() -> void:
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_data(d: Dictionary) -> void:
	data = d
	render()


func is_line_open(id: String) -> bool:
	return id.begins_with("set:") or id.begins_with("affix:") or open_lines.has(id)


func toggle_line(id: String) -> void:
	if id.begins_with("set:") or id.begins_with("affix:"):
		return
	if open_lines.has(id):
		open_lines.erase(id)
	else:
		open_lines[id] = true
	line_toggled.emit(id, open_lines.has(id))
	render()


func render() -> void:
	DmPa.clear(self)
	if not bool(data.get("ready", true)) or data.is_empty():
		add_child(_primer("Your character is not ready yet."))
		return
	add_child(_looking(data.get("looking", {})))
	add_child(DmPa.margin(_primer(String(data.get("primer", ""))), 0, 0, 0, 12))
	var first := true
	for s in data.get("sections", []):
		var h := DmPa.text(DmUi.upper(String(s["title"])), 15, DmUi.SPELL_300, "display", false)
		add_child(DmPa.margin(h, 0, 0 if first else 14, 0, 6))
		first = false
		for l in s["lines"]:
			add_child(_line(l))
	add_child(DmPa.margin(DmPa.text("Click a line to see where its number comes from. Brews and other timed effects are not included.", 12, DmUi.TEXT_FAINT), 0, 10, 0, 0))


func _primer(t: String) -> Control:
	var c := DmPa.card(DmUi.BORDER, DmUi.INSET, Vector2(10, 8))
	DmPa.card_body(c).add_child(DmPa.text(t, 13, DmUi.BONE_300))
	c.set_meta("role", "primer")
	return c


func _looking(l: Dictionary) -> Control:
	var c := DmPa.card(DmUi.BORDER_STRONG, DmUi.INSET, Vector2(12, 10))
	c.set_meta("role", "looking")
	var b := DmPa.card_body(c)
	b.add_theme_constant_override("separation", 4)
	b.add_child(DmPa.text(DmUi.upper("What you're looking for"), 15, DmUi.SPELL_300, "display", false))
	var pri := DmPa.hbox(8)
	pri.add_child(DmPa.text(String(l.get("orderText", "")), 17, DmUi.BONE_100, "numeric", false))
	var d := DmPa.text(String(l.get("discipline", "")), 12, DmUi.TEXT_FAINT, "body", false)
	d.size_flags_vertical = Control.SIZE_SHRINK_END
	pri.add_child(d)
	b.add_child(pri)
	b.add_child(DmPa.text(String(l.get("why", "")), 13, DmUi.BONE_300))
	if String(l.get("weapons", "")) != "":
		b.add_child(DmPa.margin(DmPa.text(DmUi.upper("Weapons"), 11, DmUi.SPELL_300, "body", false), 0, 6, 0, 0))
		b.add_child(DmPa.text(String(l["weapons"]), 13, DmUi.BONE_300))
	var weak: Array = l.get("weakest", [])
	if not weak.is_empty():
		b.add_child(DmPa.margin(DmPa.text(DmUi.upper("Weakest slots"), 11, DmUi.SPELL_300, "body", false), 0, 6, 0, 0))
		for w in weak:
			var h := DmPa.hbox(6)
			var worn := not bool(w.get("empty", false))
			var mk := DmPa.text("●" if worn else "▲", 11, DmUi.TEXT_FAINT if worn else DmUi.UP, "body", false)
			mk.custom_minimum_size.x = 12
			mk.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			h.add_child(mk)
			h.add_child(DmPa.text(String(w["text"]), 13, DmUi.BONE_300))
			b.add_child(h)
	var ar := DmPa.rich_bb("[color=#8fe36a]▲[/color] in your bag = better for you than what you wear. [color=#ff7b6b]▼[/color] = worse.", 12, DmUi.TEXT_FAINT)
	b.add_child(DmPa.margin(ar, 0, 6, 0, 0))
	return c


func _line(l: Dictionary) -> Control:
	var id := String(l["id"])
	var is_set := id.begins_with("set:") or id.begins_with("affix:")
	var open := is_line_open(id)
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 0)
	wrap.set_meta("line", id)
	wrap.set_meta("open", open)
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.theme_type_variation = "DmLink"
	btn.custom_minimum_size = Vector2(0, 30)
	if not is_set:
		btn.set_meta("act", "line")
		btn.set_meta("arg", id)
		btn.pressed.connect(toggle_line.bind(id))
	else:
		btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := DmPa.hbox(10)
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 4
	h.offset_right = -4
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var chev := DmPa.text("▾" if open else "▸", 14, DmUi.TEXT_FAINT, "body", false)
	chev.custom_minimum_size.x = 10
	chev.modulate.a = 0.0 if is_set else 1.0
	chev.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(chev)
	var lbl := DmPa.text(String(l["label"]), 14, DmUi.BONE_300, "body", false)
	lbl.custom_minimum_size.x = LBL_W
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(lbl)
	var val := DmPa.text(String(l["value"]), 15, DmUi.OK if is_set else DmUi.BONE_100, "numeric", false)
	val.custom_minimum_size.x = VAL_W
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(val)
	var help := DmPa.text(String(l.get("help", "")), 12, DmUi.TEXT_FAINT, "body", false)
	help.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	help.clip_text = true
	help.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	help.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(help)
	btn.add_child(h)
	wrap.add_child(btn)
	if open:
		var rows := DmPa.vbox(1)
		for r in l.get("rows", []):
			rows.add_child(_row(r, is_set))
		wrap.add_child(DmPa.margin(rows, 134, 2, 4, 8))
	wrap.add_child(DmUi.hrule(Color(DmUi.BONE_300, 0.08)))
	return wrap


func _row(r: Dictionary, is_set: bool) -> Control:
	var tone := String(r.get("tone", ""))
	var total := bool(r.get("total", false))
	var h := DmPa.hbox(12)
	h.custom_minimum_size.x = 0
	var col := DmUi.BONE_300
	if total:
		col = DmUi.BONE_100
	var lab := DmPa.text(String(r["label"]), 12, DmUi.OK if (tone == "up" and is_set) else col, "numeric_medium", true)
	h.add_child(lab)
	var vcol := col
	if tone == "up":
		vcol = DmUi.OK
	elif tone == "down":
		vcol = RED
	elif is_set:
		vcol = DmUi.TEXT_FAINT
	var v := DmPa.text(String(r["value"]), 12, vcol, "numeric", false)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(v)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.custom_minimum_size.x = 0
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if total:
		box.add_child(DmUi.hrule())
	box.add_child(h)
	box.set_meta("row", true)
	return box
