class_name DmFx
extends RefCounted
## Tiny visual helpers: floating text (damage / loot), a flat ring decal.

static func float_text(parent: Node, pos: Vector3, text: String, color: Color, size: int = 40, rise: float = 1.4, life: float = 0.9) -> void:
	var l := Label3D.new()
	l.text = text
	l.modulate = color
	l.outline_modulate = Color(0, 0, 0, 0.9)
	l.outline_size = 10
	l.font_size = size
	l.pixel_size = 0.012
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = false
	l.position = pos
	parent.add_child(l)
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", pos.y + rise, life)
	tw.tween_property(l, "modulate:a", 0.0, life).set_delay(life * 0.5)
	tw.chain().tween_callback(l.queue_free)
