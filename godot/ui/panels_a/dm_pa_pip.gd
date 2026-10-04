class_name DmPaPip
extends Control
## A boon rank pip: 8px amber diamond, filled when owned (.cw-ascend .boon .pips i).

var on := false


func _init() -> void:
	custom_minimum_size = Vector2(12, 12)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var c := size * 0.5
	var r := 5.0
	var pts := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])
	var amber := Color("d9a441")
	if on:
		draw_colored_polygon(pts, amber)
	pts.append(pts[0])
	draw_polyline(pts, amber, 1.0, true)
