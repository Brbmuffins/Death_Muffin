class_name DmPlateFill
extends Control
## A plate's painted background: CSS `linear-gradient(angle, a, b)` (true CSS geometry, pixel-space isolines) with the optional `--cw-engrave` layer on top
## (`linear-gradient(145deg, rgba(238,231,210,.03), transparent 30%)` + 1px / 3px horizontal hairlines at 1.2% white). The login card uses it
## (`.cw-login`: engrave over linear-gradient(150deg, rgba(29,20,30,.97), rgba(10,8,14,.98))). Add it as the FIRST child of the card so the content draws over it.

@export var angle_deg := 150.0
@export var from_color := Color(0.1137, 0.0784, 0.1176, 0.97)
@export var to_color := Color(0.0392, 0.0314, 0.0549, 0.98)
@export var engrave := true
@export var inset_highlight := Color(0.941, 0.914, 0.863, 0.07)   # box-shadow: inset 0 1px 0

static var _lines: ImageTexture


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


## Points of `rect` with t = projection onto the gradient line of angle `deg` (CSS: 0deg = up, clockwise), t = 0 at the start corner, 1 at the end corner.
static func css_t(p: Vector2, rect: Rect2, deg: float) -> float:
	var a := deg_to_rad(deg)
	var dir := Vector2(sin(a), -cos(a))
	var length := absf(rect.size.x * sin(a)) + absf(rect.size.y * cos(a))
	var c := rect.position + rect.size * 0.5
	return (p - c).dot(dir) / maxf(length, 0.0001) + 0.5


static func _clip(poly: PackedVector2Array, rect: Rect2, deg: float, t_lo: float, t_hi: float) -> PackedVector2Array:
	var out := poly
	for pass_i in 2:
		var keep_ge := pass_i == 0
		var edge := t_lo if keep_ge else t_hi
		var res := PackedVector2Array()
		for i in out.size():
			var a := out[i]
			var b := out[(i + 1) % out.size()]
			var ta := css_t(a, rect, deg) - edge
			var tb := css_t(b, rect, deg) - edge
			var ina := ta >= 0.0 if keep_ge else ta <= 0.0
			var inb := tb >= 0.0 if keep_ge else tb <= 0.0
			if ina:
				res.append(a)
			if ina != inb:
				var k := ta / (ta - tb)
				res.append(a.lerp(b, k))
		out = res
		if out.is_empty():
			break
	return out


func _band(rect: Rect2, t0: float, t1: float, c0: Color, c1: Color) -> void:
	var poly := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	var clipped := _clip(poly, rect, angle_deg, t0, t1)
	if clipped.size() < 3:
		return
	var cols := PackedColorArray()
	for p in clipped:
		var t := clampf((css_t(p, rect, angle_deg) - t0) / maxf(t1 - t0, 0.0001), 0.0, 1.0)
		cols.append(c0.lerp(c1, t))
	draw_polygon(clipped, cols)


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	_band(r, 0.0, 1.0, from_color, to_color)   # the plate's own gradient (comes from the parent's rect: it is the plate's fill)
	if engrave:
		var saved := angle_deg
		angle_deg = 145.0
		_band(r, 0.0, 0.3, Color(0.9333, 0.9059, 0.8235, 0.03), Color(0.9333, 0.9059, 0.8235, 0.0))
		angle_deg = saved
		if _lines == null:
			var img := Image.create(1, 3, false, Image.FORMAT_RGBA8)
			img.set_pixel(0, 0, Color(1, 1, 1, 0.012))
			img.set_pixel(0, 1, Color(1, 1, 1, 0.0))
			img.set_pixel(0, 2, Color(1, 1, 1, 0.0))
			_lines = ImageTexture.create_from_image(img)
		draw_texture_rect(_lines, r, true)
	if inset_highlight.a > 0.0:
		draw_rect(Rect2(1, 1, size.x - 2.0, 1.0), inset_highlight)
