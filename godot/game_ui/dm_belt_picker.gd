class_name DmBeltPicker
extends PanelContainer
## Port of src/ui/BeltPicker.ts: click a Z / X slot on the HUD belt and choose which brew from the bag it holds. Built on demand. (Dropping a brew
## from the Reliquary onto the slot is DmHud.brew_dropped.)

var ui: Node
var slot_name := ""
var rows: Array = []        ## the choices drawn: {id, label, glyph, color, effect, count, current}
var _vb: VBoxContainer


func _init(ui_: Node = null) -> void:
	ui = ui_
	theme = DmUi.theme()
	theme_type_variation = "DmPlate"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_vb = VBoxContainer.new()
	_vb.add_theme_constant_override("separation", 4)
	add_child(_vb)
	custom_minimum_size.x = 260
	if ui != null:
		ui.windows_root.add_child(self)


static func picker_title(slot_label: String, key: String) -> String:
	return "%s slot · key %s" % [slot_label, key]


static func empty_text(slot_label: String) -> String:
	var kind := slot_label.to_lower()
	return "No %ss in your bag. Brew %s %s in the Alchemist's Wing (the Chapterhouse's east door), then click here again." % [kind, "an" if kind == "elixir" else "a", kind]


func choices(slot: String) -> Array:
	var on := belt_brew(slot)
	var out: Array = []
	for id in DmContent.brews():
		var b: Dictionary = DmContent.brews()[id]
		if b["slot"] == slot and ui.inv.count(id) > 0:
			out.append({"id": id, "label": b["label"], "glyph": b["glyph"], "color": int(b["color"]), "effect": "%s · %ss" % [DmUiBrews.effects_text(b), DmJsFmt.num_str(float(b["seconds"]))],
				"count": ui.inv.count(id), "current": id == on})
	return out


## The brew a belt key drinks: the chosen one while the bag has it, else the first of that slot you carry.
func belt_brew(slot: String) -> String:
	var pick: Variant = ui.belt_pick().get(slot)
	if pick is String and ui.inv.count(pick) > 0:
		return pick
	for id in DmContent.brews():
		if DmContent.brews()[id]["slot"] == slot and ui.inv.count(id) > 0:
			return id
	return ""


func toggle(slot: String) -> void:
	if slot != "elixir" and slot != "tonic":
		return
	if visible:
		close()
		return
	open(slot)


func open(slot: String) -> void:
	close()
	slot_name = "Elixir" if slot == "elixir" else "Tonic"
	var key := "Z" if slot == "elixir" else "X"
	for c in _vb.get_children():
		c.queue_free()
	var head := DmUi.label(DmUi.upper(picker_title(slot_name, key)), "DmSub")
	_vb.add_child(head)
	rows = choices(slot)
	if rows.is_empty():
		_vb.add_child(DmUi.label(empty_text(slot_name), "DmMuted", true))
	for r in rows:
		var b := Button.new()
		b.theme_type_variation = "DmButtonSmall"
		b.focus_mode = Control.FOCUS_NONE
		b.text = "%s  %s  ·  %s%s  ×%d" % [r["glyph"], r["label"], "on belt · " if r["current"] else "", r["effect"], int(r["count"])]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var id: String = r["id"]
		b.pressed.connect(func() -> void:
			close()
			ui.set_belt(id))
		_vb.add_child(b)
	var foot := DmUi.label("You can also drag a brew from your bag onto the slot.", "DmFaint", true)
	_vb.add_child(foot)
	var chips: Variant = ui.hud.brews_box
	position = (chips as Control).global_position + Vector2(((chips as Control).size.x) + 8, 0)
	visible = true


func close() -> void:
	visible = false


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and not get_global_rect().has_point(event.position):
		close()
