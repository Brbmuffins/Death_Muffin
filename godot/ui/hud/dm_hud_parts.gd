class_name DmHudParts
extends RefCounted
## Tiny draw-only controls the HUD composes: diamond rows (thrall pips, upgrade milestone gems), the level badge, the screen-edge
## vignette, the "NEW" glow and the dark death wash.


## A row of rotated squares: `.hud-thralls i` (12 px, bone fill + jade glow when on) and `.hud-up .gems i` (8 px, spell-300).
class Diamonds extends Control:
	var on: Array = []
	var side: float = 12.0
	var gap: float = 6.0
	var fill_on: Color = DmUi.BONE_300
	var edge_on: Color = DmUi.BONE_100
	var edge_off: Color = DmUi.BORDER_STRONG
	var glow_on: Color = Color(0.435, 0.89, 0.784, 0.75)

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_state(flags: Array) -> void:
		on = flags
		var n := flags.size()
		custom_minimum_size = Vector2(n * side + maxi(n - 1, 0) * gap, maxf(side, 0.0))
		queue_redraw()

	func _draw() -> void:
		for i in on.size():
			var c := Vector2(i * (side + gap) + side * 0.5, side * 0.5)
			var h := side * 0.5
			var pts := PackedVector2Array([c + Vector2(0, -h * 1.4142), c + Vector2(h * 1.4142, 0), c + Vector2(0, h * 1.4142), c + Vector2(-h * 1.4142, 0)])
			pts = _shrink(pts, c, 0.82)
			if on[i]:
				for k in 3:
					draw_colored_polygon(_shrink(pts, c, 1.0 + 0.22 * (k + 1)), Color(glow_on, glow_on.a * 0.14))
				draw_colored_polygon(pts, fill_on)
			var closed := pts.duplicate()
			closed.append(pts[0])
			draw_polyline(closed, edge_on if on[i] else edge_off, 1.0)

	static func _shrink(pts: PackedVector2Array, c: Vector2, k: float) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in pts:
			out.append(c + (p - c) * k)
		return out


## `.hud-level`: 44 px badge, radial #1d1624 -> #07060a, strong border + two thin rings.
class LevelBadge extends Control:
	var text: Label

	func _init() -> void:
		custom_minimum_size = Vector2(44, 44)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		text = DmHudKit.lbl("1", 20, DmUi.BONE_100, "display_bold", false)
		text.set_anchors_preset(Control.PRESET_FULL_RECT)
		text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(text)

	func _draw() -> void:
		var c := size * 0.5
		var r := 22.0
		draw_circle(c, r + 4.0, DmUi.BORDER)
		draw_circle(c, r + 3.0, Color("0b090e"))
		draw_circle(c, r, DmUi.BORDER_STRONG)
		draw_circle(c, r - 1.0, Color("07060a"))
		draw_circle(c, (r - 1.0) * 0.6, Color("120d17"))
		draw_circle(c, (r - 1.0) * 0.3, Color("1d1624"))


## The screen-edge wash: `inset 0 0 180px 40px rgba(110,30,70,a)`. strength = alpha at the very edge.
class Vignette extends Control:
	var strength: float = 0.0: set = _set_strength
	var _target: float = 0.0
	var _rate: float = 3.0
	var hit_left: float = 0.0
	var low: bool = false

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _set_strength(v: float) -> void:
		strength = v
		queue_redraw()

	func flash() -> void:
		hit_left = 0.09

	## Target strength for the current state: hit 0.55 > low-hp 0.45 > none; eases at `transition: box-shadow .3s`.
	func _process(delta: float) -> void:
		if hit_left > 0.0:
			hit_left = maxf(0.0, hit_left - delta)
			strength = 0.55
			return
		_target = 0.45 if low else 0.0
		strength = move_toward(strength, _target, delta / 0.3 * 0.55)

	func _draw() -> void:
		if strength <= 0.003:
			return
		var steps := 22
		var depth := 200.0
		for i in steps:
			var t := float(i) / steps
			var a := strength * pow(1.0 - t, 2.2) * 0.55
			var w := depth / steps
			var off := i * w
			var col := Color(0.431, 0.118, 0.275, a)
			draw_rect(Rect2(off, off, size.x - 2 * off, w), col)
			draw_rect(Rect2(off, size.y - off - w, size.x - 2 * off, w), col)
			draw_rect(Rect2(off, off + w, w, size.y - 2 * off - 2 * w), col)
			draw_rect(Rect2(size.x - off - w, off + w, w, size.y - 2 * off - 2 * w), col)


## `.dm-glow`: a gold edge + soft halo that pulses while a NEW element has not been used yet.
class NewGlow extends Control:
	var active: bool = false: set = _set_active
	var _t: float = 0.0

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		visible = false

	func _set_active(a: bool) -> void:
		active = a
		visible = a
		set_process(a)
		queue_redraw()

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var k := 0.5 + 0.5 * sin(_t / 1.6 * TAU)
		draw_rect(r, DmUi.GOLD, false, 1.0)
		for i in 5:
			draw_rect(r.grow(1.0 + i * 2.0), Color(DmUi.GOLD, 0.55 * k * (1.0 - i / 5.0) * 0.4), false, 2.0)


## A PanelContainer forces every child to fill it, so overlays (NEW pip, glow) cannot be children of a panel. This plain Control
## hosts the panel and the overlays side by side and tracks the panel's size.
class OverlayHost extends Control:
	var inner: Control

	func _init(panel: Control) -> void:
		inner = panel
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(panel)
		panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
		panel.minimum_size_changed.connect(_sync)
		_sync()

	func _sync() -> void:
		custom_minimum_size = inner.get_combined_minimum_size()
		inner.size = size if size.x >= custom_minimum_size.x else custom_minimum_size

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED and inner != null:
			inner.size = size
