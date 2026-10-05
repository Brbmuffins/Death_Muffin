class_name DmPaIcon
extends Control
## A square art slot (ability icon, item icon, portrait). Loads `res://assets/<path>` when the file has been synced into the project;
## until then it draws a stable placeholder tile (colour from the id, a glyph) so layouts and screenshots are honest about size.

var path := ""
var seed_text := ""
var glyph := ""
var tex: Texture2D
var border := DmUi.BORDER_STRONG


func setup(p: String, px: int, seed_in: String, glyph_in: String = "") -> void:
	path = p
	seed_text = seed_in
	glyph = glyph_in
	custom_minimum_size = Vector2(px, px)
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex = DmUiArt.texture(p)


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if tex != null:
		draw_texture_rect(tex, r, false)
	else:
		var h := hash(seed_text)
		var col := Color.from_hsv(float(h % 360) / 360.0, 0.35, 0.42)
		draw_rect(r, col.darkened(0.45))
		draw_rect(r.grow(-size.x * 0.18), col)
		if glyph != "":
			var f := DmUi.font("display_bold")
			var fs := int(size.x * 0.5)
			var gs := f.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			draw_string(f, Vector2((size.x - gs.x) * 0.5, (size.y + gs.y * 0.55) * 0.5), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.55))
	draw_rect(r, border, false, 1.0)
	draw_rect(r.grow(-1), Color("07060a"), false, 2.0)
