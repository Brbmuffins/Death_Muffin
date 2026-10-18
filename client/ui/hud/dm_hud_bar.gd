class_name DmHudBar
extends Control
## A thin HUD track: inset background, 1px border, left-to-right gradient fill, optional glow and fixed tick marks.
## Drawn from the HUD atlas on the chrome layer (DmHudKit), so a bar adds no draw calls of its own.
## Mirrors the web's `.track > .fill` pairs (xp bar, target/boss hp, chain timer, depth, upgrade bars, party hp, soul meter).

var value: float = 0.0: set = set_value
var fill_a: Color = DmUi.BONE_300
var fill_b: Color = DmUi.BONE_300
var bg: Color = DmUi.INSET
var border: Color = DmUi.BORDER
var mid: Color = Color(0, 0, 0, 0)  ## optional 3rd stop (boss bar), at `mid_at` of the fill width
var mid_at: float = 0.6
var glow: Color = Color(0, 0, 0, 0)
var marks: Array[float] = []
var mark_color: Color = Color(DmUi.BONE_300, 0.6)
var mark_w: float = 2.0
var overshoot: float = 0.0  ## marks extend this many px above/below the track (boss bar: 4)


func _init(h: float = 6.0, w: float = 0.0) -> void:
	z_index = DmHudKit.Z_CHROME
	custom_minimum_size = Vector2(w, h)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL if w == 0.0 else Control.SIZE_FILL


func setup(a: Color, b: Color, bg_: Color = DmUi.INSET, border_: Color = DmUi.BORDER, glow_: Color = Color(0, 0, 0, 0)) -> DmHudBar:
	fill_a = a
	fill_b = b
	bg = bg_
	border = border_
	glow = glow_
	queue_redraw()
	return self


func set_value(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if is_equal_approx(v, value):
		return
	value = v
	queue_redraw()


func _draw() -> void:
	# Everything is a rectangle of the HUD atlas (DmHudKit.rect), so a bar costs no draw calls of its own: it joins the one batch of the HUD's chrome.
	var r := Rect2(Vector2.ZERO, size)
	if bg.a > 0.0:
		DmHudKit.rect(self, r, bg)
	var inner := r.grow(-1.0)
	var w := inner.size.x * value
	if w > 0.0:
		if glow.a > 0.0:
			for i in 3:
				DmHudKit.rect(self, Rect2(inner.position - Vector2(i + 1, i + 1), Vector2(w + 2 * (i + 1), inner.size.y + 2 * (i + 1))), Color(glow, glow.a * 0.18))
		# the web's gradient spans the fill element itself, so the end colour is always at the fill's right edge
		if mid.a <= 0.0 and fill_a == fill_b:
			DmHudKit.rect(self, Rect2(inner.position, Vector2(w, inner.size.y)), fill_a)
		elif mid.a > 0.0:
			var wm := w * mid_at
			DmHudKit.gradient_rect(self, Rect2(inner.position, Vector2(wm, inner.size.y)), fill_a, mid)
			DmHudKit.gradient_rect(self, Rect2(inner.position + Vector2(wm, 0.0), Vector2(w - wm, inner.size.y)), mid, fill_b)
		else:
			DmHudKit.gradient_rect(self, Rect2(inner.position, Vector2(w, inner.size.y)), fill_a, fill_b)
	if border.a > 0.0:
		DmHudKit.outline(self, r, border, 1.0)
	for m in marks:
		var x := size.x * m
		DmHudKit.rect(self, Rect2(x - mark_w * 0.5, -overshoot, mark_w, size.y + overshoot * 2.0), mark_color)
