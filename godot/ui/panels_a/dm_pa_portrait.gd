class_name DmPaPortrait
extends Control
## Class portrait (3:4, full width of its card). Uses res://assets/<path> once synced; else a tinted placeholder with the class initial.

var tex: Texture2D
var seed_text := ""
var tint := Color.WHITE
var label := ""
var fixed_size := Vector2.ZERO   # set for a fixed-size portrait (Codex entries); else 3:4 of the width


func setup(path: String, id: String, color: Color) -> void:
	seed_text = id
	tint = color
	label = id.substr(0, 1).to_upper()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for root in ["res://assets/", "res://assets/slice/"]:
		if path != "" and ResourceLoader.exists(root + path):
			tex = load(root + path)
			break
	resized.connect(queue_redraw)


func _get_minimum_size() -> Vector2:
	if fixed_size != Vector2.ZERO:
		return fixed_size
	return Vector2(0, size.x * 4.0 / 3.0 if size.x > 0 else 120)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		update_minimum_size()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if tex != null:
		draw_texture_rect(tex, r, false)
		return
	draw_rect(r, tint.darkened(0.78))
	draw_rect(Rect2(0, size.y * 0.55, size.x, size.y * 0.45), tint.darkened(0.6))
	draw_circle(Vector2(size.x * 0.5, size.y * 0.36), size.x * 0.17, tint.darkened(0.25))
	draw_rect(Rect2(size.x * 0.28, size.y * 0.5, size.x * 0.44, size.y * 0.5), tint.darkened(0.35))
	var f := DmUi.font("display_bold")
	var gs := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 40)
	draw_string(f, Vector2((size.x - gs.x) * 0.5, size.y * 0.9), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color(1, 1, 1, 0.35))
