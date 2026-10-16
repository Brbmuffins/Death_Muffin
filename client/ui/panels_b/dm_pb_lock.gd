class_name DmPbLock
extends Control
## The small gold padlock (LOCK_SVG) used in list rows: 12x14, shackle arc over a filled body.


func _init(col: Color = DmUi.GOLD) -> void:
	custom_minimum_size = Vector2(12, 14)
	modulate = col
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


func _draw() -> void:
	draw_arc(Vector2(6, 5), 3.5, PI, TAU, 12, Color.WHITE, 1.6)
	draw_line(Vector2(2.5, 5), Vector2(2.5, 6.5), Color.WHITE, 1.6)
	draw_line(Vector2(9.5, 5), Vector2(9.5, 6.5), Color.WHITE, 1.6)
	draw_rect(Rect2(1, 6.5, 10, 7), Color.WHITE)
