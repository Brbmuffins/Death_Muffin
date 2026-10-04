class_name DmSliceHud
extends CanvasLayer
## Minimal HUD (PLACEHOLDER for the full UI track): hp / essence bars, thralls, kills, area title, key hints, recent events.

var main: DmMain
var hp_bar: ProgressBar
var ess_bar: ProgressBar
var info: Label
var area_label: Label
var notes: Label
var _note_lines: Array[String] = []

func _mk_bar(y: float, col: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.position = Vector2(16, y)
	b.size = Vector2(240, 18)
	b.show_percentage = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	b.add_theme_stylebox_override("fill", sb)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.04, 0.08, 0.85)
	b.add_theme_stylebox_override("background", bg)
	add_child(b)
	return b

func setup(m: DmMain) -> void:
	main = m
	layer = 10
	hp_bar = _mk_bar(14, Color(0.72, 0.16, 0.16))
	ess_bar = _mk_bar(38, Color(0.45, 0.3, 0.85))
	info = Label.new()
	info.position = Vector2(16, 62)
	add_child(info)
	area_label = Label.new()
	area_label.add_theme_font_size_override("font_size", 22)
	area_label.position = Vector2(300, 12)
	area_label.text = ""
	add_child(area_label)
	notes = Label.new()
	notes.position = Vector2(16, 100)
	notes.modulate = Color(0.85, 0.82, 0.75)
	add_child(notes)
	var hint := Label.new()
	hint.text = "WASD / click: move   LMB on enemy: Bone Needle   Shift+LMB: fire at cursor   1: Exhume corpse -> thrall   Wheel: zoom   F3: perf"
	hint.anchor_top = 1.0
	hint.anchor_bottom = 1.0
	hint.position = Vector2(16, -30)
	hint.modulate = Color(0.8, 0.78, 0.7, 0.8)
	add_child(hint)

func on_area(a: Dictionary) -> void:
	area_label.text = "%s  -  %s" % [a.name, a.subtitle]

func note(s: String) -> void:
	_note_lines.append(s)
	while _note_lines.size() > 4:
		_note_lines.pop_front()
	notes.text = "\n".join(_note_lines)

func _process(_dt: float) -> void:
	var h := main.hero
	hp_bar.max_value = h.max_hp
	hp_bar.value = h.hp
	ess_bar.max_value = h.max_essence
	ess_bar.value = h.essence
	info.text = "HP %d/%d   Essence %d   Thralls %d/%d   Kills %d   Enemies %d" % [int(h.hp), int(h.max_hp), int(h.essence), get_tree().get_nodes_in_group("thralls").size(), int(main.hero_data.discipline.thrallCap), main.kills, get_tree().get_nodes_in_group("enemies").size()]
