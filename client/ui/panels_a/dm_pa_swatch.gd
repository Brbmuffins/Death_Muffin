class_name DmPaSwatch
extends Control
## Cape swatch (a 44px coloured block with a trim bar along the bottom) or a pet tile (rarity-tinted with a glyph).

var body_color := Color.WHITE
var trim_color := Color.TRANSPARENT
var pet_glyph := ""


func _init() -> void:
	custom_minimum_size = Vector2(44, 44)
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if pet_glyph != "":
		draw_rect(r, Color("09060c"))
		draw_rect(r, Color(body_color, 0.8), false, 1.0)
		var f := DmUi.font("display_bold")
		var gs := f.get_string_size(pet_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 26)
		draw_string(f, Vector2((size.x - gs.x) * 0.5, (size.y + gs.y * 0.5) * 0.5), pet_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, body_color)
		return
	draw_rect(r, body_color)
	draw_rect(Rect2(0, size.y - 6, size.x, 6), trim_color)
	draw_rect(r, DmUi.BORDER_STRONG, false, 1.0)
