class_name DmIconButton
extends Button
## .cw-icon-btn: 40x40 inset square. The glyph ("close" X, "up" arrow) is drawn by an overlay so it never depends on font coverage.

@export_enum("close", "up", "none") var glyph: String = "close"
var _overlay: Control


func _init() -> void:
	theme_type_variation = "DmIconButton"
	custom_minimum_size = Vector2(40, 40)
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_glyph)
	add_child(_overlay)
	mouse_entered.connect(_overlay.queue_redraw)
	mouse_exited.connect(_overlay.queue_redraw)


func _draw_glyph() -> void:
	var c := _overlay.size * 0.5
	var col := DmUi.BONE_100 if is_hovered() else DmUi.BONE_300
	if glyph == "close":
		var r := 5.0
		_overlay.draw_line(c + Vector2(-r, -r), c + Vector2(r, r), col, 1.6, true)
		_overlay.draw_line(c + Vector2(-r, r), c + Vector2(r, -r), col, 1.6, true)
	elif glyph == "up":
		_overlay.draw_polyline(PackedVector2Array([c + Vector2(-5, 2), c + Vector2(0, -3), c + Vector2(5, 2)]), col, 1.8, true)
