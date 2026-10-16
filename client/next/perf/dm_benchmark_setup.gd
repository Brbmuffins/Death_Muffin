class_name DmBenchmarkSetup
extends Control
## The window the character select's Benchmark button opens: room, class, fight size and length (DmBenchmark.ROOMS / class_indices / SIZES /
## LENGTHS), Start / Back (Esc). It opens on the last setup used (`FILE`, per PC) and says whether the pick is the Standard setup (the one
## that compares PCs) or a custom one. `start(setup)` hands the pick to main, which runs DmBenchmarkScreen with it. Ported to the rebuilt client (client/code.list "Ported"):
## the rooms and classes it lists are the ones the client has (DmBenchmark.ROOMS / CLASSES), and the upload note names the test server.

signal start(setup: Dictionary)
signal closed

const FILE := "user://benchmarks/setup.json"

var setup: Dictionary = {}
var _room: OptionButton
var _class: OptionButton
var _size: OptionButton
var _length: OptionButton
var _note: Label


func _ready() -> void:
	theme = DmUi.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # the select screen underneath takes no clicks while this is open
	setup = load_last()
	var dim := ColorRect.new()
	dim.color = Color(DmUi.VOID_950, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var plate := PanelContainer.new()
	plate.theme_type_variation = "DmPlate"
	plate.custom_minimum_size.x = 520
	center.add_child(plate)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	plate.add_child(v)
	var title := DmFrontUi.lbl("BENCHMARK", "display", 28, DmUi.BONE_300, 4.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	v.add_child(DmFrontUi.lbl("Runs a held fight on this PC and measures it. Offline: your characters are not touched.", "body", 14, DmUi.TEXT_MUTED, 0.0, true))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 8)
	v.add_child(grid)
	_room = _row(grid, "Room")
	for id: String in DmBenchmark.ROOMS:
		_add(_room, DmBenchmark.room_name(id) + ("  (standard)" if id == DmBenchmark.STANDARD["room"] else ""), id)
	_class = _row(grid, "Class")
	for i: int in DmBenchmark.class_indices():
		_add(_class, DmBenchmark.class_name_of(i) + ("  (standard)" if i == DmBenchmark.STANDARD["discipline"] else ""), i)
	_size = _row(grid, "Fight size")
	for k: String in DmBenchmark.SIZES:
		_add(_size, "%s: %d enemies, %d thralls%s" % [DmBenchmark.SIZE_NAMES[k], DmBenchmark.SIZES[k][0], DmBenchmark.SIZES[k][1], ", a boss" if DmBenchmark.BOSS_SIZES.has(k) else ""], k)
	_length = _row(grid, "Length")
	for k: String in DmBenchmark.LENGTHS:
		_add(_length, DmBenchmark.LENGTH_NAMES[k] + ("" if DmBenchmark.LENGTHS[k][2] else ", no render breakdown"), k)
	_note = DmFrontUi.lbl("", "body", 14, DmUi.SPELL_300, 0.0, true)
	v.add_child(_note)
	v.add_child(DmFrontUi.lbl("Every finished run is added to the benchmark history of the test server with your name and this PC's GPU and CPU.",
		"body", 12, DmUi.TEXT_FAINT, 0.0, true))
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 14)
	v.add_child(btns)
	var reset := Button.new()
	reset.text = "Standard setup"
	reset.tooltip_text = "%s: the setup whose numbers compare between PCs." % DmBenchmark.setup_label(DmBenchmark.STANDARD)
	reset.pressed.connect(func() -> void:
		setup = DmBenchmark.STANDARD.duplicate()
		_show())
	btns.add_child(reset)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(func() -> void: closed.emit())
	btns.add_child(back)
	var go := Button.new()
	go.text = "Start"
	go.theme_type_variation = "DmButtonPrimary"
	go.pressed.connect(_start)
	btns.add_child(go)
	for ob: OptionButton in [_room, _class, _size, _length]:
		ob.item_selected.connect(func(_i: int) -> void: _read_picks())
	_show()
	go.grab_focus()


func _row(grid: GridContainer, label: String) -> OptionButton:
	grid.add_child(DmFrontUi.lbl(label, "body", 15, DmUi.TEXT_MUTED))
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(ob)
	return ob


func _add(ob: OptionButton, text: String, value: Variant) -> void:
	ob.add_item(text)
	ob.set_item_metadata(ob.item_count - 1, value)


func _select(ob: OptionButton, value: Variant) -> void:
	for i in ob.item_count:
		if ob.get_item_metadata(i) == value:
			ob.select(i)


func _show() -> void:
	_select(_room, setup["room"])
	_select(_class, setup["discipline"])
	_select(_size, setup["size"])
	_select(_length, setup["length"])
	_update_note()


func _read_picks() -> void:
	setup = DmBenchmark.normalize_setup({"room": _room.get_selected_metadata(), "discipline": _class.get_selected_metadata(),
		"size": _size.get_selected_metadata(), "length": _length.get_selected_metadata()})
	_update_note()


func _update_note() -> void:
	_note.text = "Standard setup: these numbers compare with any other PC's." if DmBenchmark.is_standard(setup) \
		else "Custom setup: compare it only with runs of the same room, class, size and length."
	if DmBenchmark.BOSS_SIZES.has(setup["size"]):
		var boss := DmBenchFight.boss_of(String(setup["room"]))
		_note.text += "\n" + ("The room's boss, %s, is held awake." % DmContent.boss(boss)["name"] if boss != "" else "This room has no boss: the fight runs without one.")


func _start() -> void:
	_read_picks()
	save_last(setup)
	start.emit(setup)


func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		closed.emit()


static func load_last() -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(FILE)) if FileAccess.file_exists(FILE) else null
	return DmBenchmark.normalize_setup(v if v is Dictionary else {})


static func save_last(s: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(FILE.get_base_dir())
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(s))
