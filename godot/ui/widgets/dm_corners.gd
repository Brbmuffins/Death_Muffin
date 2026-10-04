class_name DmCorners
extends Control
## The chipped carved corners of `.cw-plate::before/::after`: top-left and bottom-right 14px brackets. Add as the LAST child of a
## plate (it draws above the fill). Mouse-transparent.

@export var arm: float = 14.0
@export var thickness: float = 2.0
@export var color: Color = DmUi.BORDER_STRONG


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _ready() -> void:
	var pc := get_parent_control()
	if pc != null:
		pc.resized.connect(queue_redraw)


func _draw() -> void:
	# Containers inset their children by the stylebox margins: draw against the PARENT's full rect instead.
	var pc := get_parent_control()
	var o := -position
	var sz := pc.size if pc != null else size
	draw_rect(Rect2(o.x, o.y, arm, thickness), color)
	draw_rect(Rect2(o.x, o.y, thickness, arm), color)
	draw_rect(Rect2(o.x + sz.x - arm, o.y + sz.y - thickness, arm, thickness), color)
	draw_rect(Rect2(o.x + sz.x - thickness, o.y + sz.y - arm, thickness, arm), color)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
