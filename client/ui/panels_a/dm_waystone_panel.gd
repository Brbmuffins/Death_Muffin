class_name DmWaystonePanel
extends DmWindow
## Fast travel between unlocked waystones (MiscPanels.ts WaystonePanel). "Waystones" aka "Map · M".
## Data in:  set_unlocked(area_ids: Array)  (area ids in the order given; names and levels come from the exported areas)
## Signals:  travel_requested(area_id)  (the panel closes first, like the web)  -> the client travels; no DmApi call.

signal travel_requested(area_id: String)

var unlocked: Array = []


func _init() -> void:
	super._init()
	title = "Waystones"
	aka = "Map · M"
	panel_width = 540


func set_unlocked(ids: Array) -> void:
	unlocked = ids
	render()


func render() -> void:
	DmPa.clear(body)
	var col := DmPa.vbox(6)
	for id in unlocked:
		var a: Dictionary = DmContent.area(String(id))
		var b := Button.new()
		b.theme_type_variation = "DmButtonSmall"
		b.focus_mode = Control.FOCUS_NONE
		b.set_meta("act", "travel")
		b.set_meta("arg", String(id))
		var h := HBoxContainer.new()
		h.set_anchors_preset(Control.PRESET_FULL_RECT)
		h.offset_left = 12
		h.offset_right = -12
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var n := DmPa.text(DmUi.upper(String(a.get("name", id))), 13, DmUi.BONE_100, "display", false)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(n)
		var lv := DmPa.text("Lv %d" % int(a.get("level", 1)), 12, DmUi.TEXT_FAINT, "body", false)
		lv.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(lv)
		b.custom_minimum_size = Vector2(0, 34)
		b.add_child(h)
		b.pressed.connect(func() -> void:
			close()
			travel_requested.emit(String(id)))
		col.add_child(b)
	body.add_child(col)
	body.add_child(DmPa.margin(DmPa.text("Waystones answer only in the Chapterhouse or beside another waystone.", 12, DmUi.TEXT_FAINT), 0, 10, 0, 0))
