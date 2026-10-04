class_name DmToast
extends PanelContainer
## `.hud-toast`: a short message strip. kind: "" | "good" | "err" | "loot" | "loot_major" | "new_cue".
## Fades in 0.25 s, holds `hold_s`, fades out 0.5 s, then frees itself. Stack several in a VBoxContainer centred under the HUD top.

var hold_s: float = 8.0
var kind: String = ""
var _label: Label


static func make(text: String, kind_: String = "", hold: float = 8.0) -> DmToast:
	var t := DmToast.new()
	t.kind = kind_
	t.hold_s = hold
	t._build(text)
	return t


func _build(text: String) -> void:
	theme = DmUi.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	match kind:
		"good": theme_type_variation = "DmToastGood"
		"err": theme_type_variation = "DmToastErr"
		"loot_major", "new_cue": theme_type_variation = "DmToastMajor"
		_: theme_type_variation = "DmToast"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	add_child(row)
	if kind == "new_cue":
		row.add_child(DmUi.new_pip("NEW"))
	_label = DmUi.label(text, "DmToastText")
	# single line unless wider than the web's max (480 px), then wrap at that width
	var fw := DmUi.font("body").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	if fw > 470.0:
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_label.custom_minimum_size.x = 470.0
	if kind == "loot":
		_label.add_theme_font_size_override("font_size", 13)
		_label.add_theme_color_override("font_color", DmUi.BONE_300)
	elif kind == "loot_major":
		_label.add_theme_color_override("font_color", Color("f1e2b8"))
	row.add_child(_label)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	modulate.a = 0.0


func _ready() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.25)
	tw.tween_interval(hold_s)
	tw.tween_property(self, "modulate:a", 0.0, 0.5)
	tw.tween_callback(queue_free)
