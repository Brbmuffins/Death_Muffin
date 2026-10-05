class_name DmCharSelectScreen
extends Control
## Port of src/scenes/CharacterSelectScene.ts: "Choose Your Discipline", nine cards. Only reached by an account with no
## character yet (resume(): 404 -> select), so the first-run discipline always carries the "Recommended" badge.
## Picking a card calls load_or_create_character(classIndex); the server error string is shown verbatim on failure.

signal selected(character: Dictionary)

const DISCIPLINES_JSON := "res://data/content/disciplines.json"
const FIRST_RUN_DISCIPLINE := "gravecaller"   # src/ui/firstHourRules.ts

var api: DmApi
var grid: GridContainer
var error_label: Label
var cards: Array[DmDisciplineCard] = []
var disciplines: Array = []
var plate: PanelContainer


func _init(api_: DmApi = null) -> void:
	api = api_


static func load_disciplines() -> Array:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(DISCIPLINES_JSON))
	return d["PLAYABLE_DISCIPLINES"] if d is Dictionary else []


func _ready() -> void:
	theme = DmUi.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = DmUi.VOID_950
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	add_child(DmNecroBackdrop.new())
	var shade := ColorRect.new()
	shade.color = Color(0.027, 0.024, 0.039, 0.5)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	plate = PanelContainer.new()
	plate.theme_type_variation = "DmPlate"
	plate.add_theme_stylebox_override("panel", DmUi.box(DmUi.PANEL, DmUi.BORDER, 1, 3, Vector2(26, 24)))
	center.add_child(plate)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	plate.add_child(v)
	var title := DmFrontUi.lbl("CHOOSE YOUR DISCIPLINE", "display", 30, DmUi.BONE_300, 4.2)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := DmFrontUi.lbl("Choose from nine disciplines, each with its own resource, rites, and way through the dead.", "display_italic", 17, DmUi.TEXT_MUTED, 0.0, true)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sm := MarginContainer.new()
	sm.add_theme_constant_override("margin_top", 6)
	sm.add_theme_constant_override("margin_bottom", 20)
	sm.add_child(sub)
	v.add_child(sm)
	grid = GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	v.add_child(grid)
	error_label = DmFrontUi.lbl("", "body", 14, DmUi.DANGER, 0.0, true)
	error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	error_label.custom_minimum_size.y = 20
	var em := MarginContainer.new()
	em.add_theme_constant_override("margin_top", 8)
	em.add_child(error_label)
	v.add_child(em)
	plate.add_child(DmCorners.new())
	disciplines = load_disciplines()
	for d in disciplines:
		var c := DmDisciplineCard.new().setup(d, String(d["id"]) == FIRST_RUN_DISCIPLINE)
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.chosen.connect(func(dd): choose(int(dd["classIndex"])))
		grid.add_child(c)
		cards.append(c)
	get_viewport().size_changed.connect(_layout)
	_layout()


func _layout() -> void:
	var w := size.x if size.x > 0.0 else get_viewport_rect().size.x
	grid.columns = 1 if w <= 560.0 else (2 if w <= 900.0 else 4)
	plate.custom_minimum_size.x = minf(1100.0, w - 32.0)


func _set_disabled(v: bool) -> void:
	for c in cards:
		c.disabled = v


## Web card click handler. Returns true when the character was created/loaded (then `selected` is emitted).
func choose(class_index: int) -> bool:
	error_label.text = ""
	_set_disabled(true)
	var r := await api.load_or_create_character(class_index)
	if r.ok and r.data is Dictionary:
		selected.emit(r.data)
		return true
	error_label.text = r.error if not r.error.is_empty() else "Could not bind you to that discipline"
	_set_disabled(false)
	return false
