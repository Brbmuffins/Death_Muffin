class_name DmPbBar
extends Control
## A thin progress bar (`.bar` in ui.css): track rgba(255,255,255,.08) with a solid fill. `pct` is 0..100.

var pct := 0.0:
	set(v):
		pct = clampf(v, 0.0, 100.0)
		queue_redraw()
var fill := DmUi.OK:
	set(v):
		fill = v
		queue_redraw()
var track := Color(1, 1, 1, 0.08)


func _init(height: float = 5.0) -> void:
	custom_minimum_size = Vector2(40, height)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), track)
	draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * pct / 100.0, size.y)), fill)
