class_name DmHudParts
extends RefCounted
## Tiny draw-only controls the HUD composes: diamond rows (thrall pips, upgrade milestone gems), the level badge, the screen-edge
## vignette, the "NEW" glow and the dark death wash.
## Ported (client/code.list): vector shapes are triangle meshes (one draw call per widget, where each polygon, circle and outline was one) and rectangles come
## from the HUD atlas (DmHudKit.rect), all on the z layers of DmHudKit.


## A row of rotated squares: `.hud-thralls i` (12 px, bone fill + jade glow when on) and `.hud-up .gems i` (8 px, spell-300).
class Diamonds extends Control:
	var on: Array = []
	var side: float = 12.0
	var gap: float = 6.0
	var fill_on: Color = DmUi.BONE_300
	var edge_on: Color = DmUi.BONE_100
	var edge_off: Color = DmUi.BORDER_STRONG
	var glow_on: Color = Color(0.435, 0.89, 0.784, 0.75)
	var fill_hurt: Color = Color("ff5a46")   ## a state of 2 (a living thrall under a third of its health) is drawn in this colour
	var _mesh := DmHudMesh.new()

	func _init() -> void:
		z_index = DmHudKit.Z_ART
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_state(flags: Array) -> void:
		if flags == on:
			return
		on = flags
		var n := flags.size()
		custom_minimum_size = Vector2(n * side + maxi(n - 1, 0) * gap, maxf(side, 0.0))
		queue_redraw()

	## Every pip's glow, fill and edge in one mesh: one draw call for the whole row.
	func _draw() -> void:
		_mesh.clear()
		for i in on.size():
			var c := Vector2(i * (side + gap) + side * 0.5, side * 0.5)
			var h := side * 0.5
			var pts := PackedVector2Array([c + Vector2(0, -h * 1.4142), c + Vector2(h * 1.4142, 0), c + Vector2(0, h * 1.4142), c + Vector2(-h * 1.4142, 0)])
			pts = _shrink(pts, c, 0.82)
			if on[i]:
				var hurt: bool = typeof(on[i]) == TYPE_INT and int(on[i]) == 2
				for k in 3:
					_mesh.convex(_shrink(pts, c, 1.0 + 0.22 * (k + 1)), Color(fill_hurt if hurt else glow_on, glow_on.a * 0.14))
				_mesh.convex(pts, fill_hurt if hurt else fill_on)
			var edge := edge_on if on[i] else edge_off
			for k in 4:
				var d := (pts[(k + 1) % 4] - pts[k]).normalized() * 0.5   # a half pixel past each end closes the corner
				_mesh.line(pts[k] - d, pts[(k + 1) % 4] + d, 1.0, edge)
		_mesh.submit(self)

	static func _shrink(pts: PackedVector2Array, c: Vector2, k: float) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in pts:
			out.append(c + (p - c) * k)
		return out


## `.hud-level`: 44 px badge, radial #1d1624 -> #07060a, strong border + two thin rings.
class LevelBadge extends Control:
	var text: Label
	static var _art: ArrayMesh   ## the six discs, around the origin: built once, shared

	func _init() -> void:
		custom_minimum_size = Vector2(44, 44)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		z_index = DmHudKit.Z_ART
		text = DmHudKit.lbl("1", 20, DmUi.BONE_100, "display_bold", false)
		text.set_anchors_preset(Control.PRESET_FULL_RECT)
		text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(text)

	func _draw() -> void:
		if _art == null:
			var m := DmHudMesh.new()
			var r := 22.0
			m.disc(Vector2.ZERO, r + 4.0, DmUi.BORDER)
			m.disc(Vector2.ZERO, r + 3.0, Color("0b090e"))
			m.disc(Vector2.ZERO, r, DmUi.BORDER_STRONG)
			m.disc(Vector2.ZERO, r - 1.0, Color("07060a"))
			m.disc(Vector2.ZERO, (r - 1.0) * 0.6, Color("120d17"))
			m.disc(Vector2.ZERO, (r - 1.0) * 0.3, Color("1d1624"))
			_art = m.to_mesh()
		DmHudKit.mesh(self, _art, Transform2D(0.0, size * 0.5))


## The screen-edge wash: `inset 0 0 180px 40px rgba(110,30,70,a)`. strength = alpha at the very edge.
class Vignette extends Control:
	var strength: float = 0.0: set = _set_strength
	var _target: float = 0.0
	var _rate: float = 3.0
	var hit_left: float = 0.0
	var low: bool = false: set = _set_low

	func _init() -> void:
		z_index = -1   # behind every panel
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _set_strength(v: float) -> void:
		if v == strength:
			return   # (the easing sets it every frame: a settled wash repaints nothing)
		strength = v
		queue_redraw()

	func _set_low(v: bool) -> void:
		if v != low:
			low = v
			set_process(true)

	func flash() -> void:
		hit_left = 0.09
		set_process(true)

	## Target strength for the current state: hit 0.55 > low-hp 0.45 > none; eases at `transition: box-shadow .3s`. Runs while it is moving, not while it rests.
	func _process(delta: float) -> void:
		if hit_left > 0.0:
			hit_left = maxf(0.0, hit_left - delta)
			strength = 0.55
			return
		_target = 0.45 if low else 0.0
		strength = move_toward(strength, _target, delta / 0.3 * 0.55)
		if strength == _target:
			set_process(false)

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
			DmHudKit.rect(self, Rect2(off, off, size.x - 2 * off, w), col)
			DmHudKit.rect(self, Rect2(off, size.y - off - w, size.x - 2 * off, w), col)
			DmHudKit.rect(self, Rect2(off, off + w, w, size.y - 2 * off - 2 * w), col)
			DmHudKit.rect(self, Rect2(size.x - off - w, off + w, w, size.y - 2 * off - 2 * w), col)


## A flat coloured strip (what a ColorRect was), drawn from the HUD atlas on the chrome layer.
class Rule extends Control:
	var color: Color = Color.WHITE

	func _init() -> void:
		z_index = DmHudKit.Z_CHROME
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		DmHudKit.rect(self, Rect2(Vector2.ZERO, size), color)


## `.dm-glow`: a gold edge + soft halo that pulses while a NEW element has not been used yet. The edge is drawn once; the halo is a child drawn once at full strength
## and faded by its `modulate.a` (the pulse), so a pulse costs one property per frame where it was a redraw of 24 rectangles.
class NewGlow extends Control:
	var active: bool = false: set = _set_active
	var _t: float = 0.0
	var _halo: Control

	func _init() -> void:
		z_index = DmHudKit.Z_EDGE
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		visible = false
		_halo = Halo.new()
		add_child(_halo)

	func _set_active(a: bool) -> void:
		active = a
		visible = a
		set_process(a)
		_halo.modulate = Color(1.0, 1.0, 1.0, _k())
		queue_redraw()

	func _k() -> float:
		return 0.5 + 0.5 * sin(_t / 1.6 * TAU)

	func _process(delta: float) -> void:
		_t += delta
		_halo.modulate = Color(1.0, 1.0, 1.0, _k())

	func _draw() -> void:
		DmHudKit.outline(self, Rect2(Vector2.ZERO, size), DmUi.GOLD, 1.0)

	## The soft halo at the pulse's peak: five rings of falling strength (the pulse scales them all by `k`).
	class Halo extends Control:
		func _init() -> void:
			set_anchors_preset(Control.PRESET_FULL_RECT)
			mouse_filter = Control.MOUSE_FILTER_IGNORE

		func _draw() -> void:
			var r := Rect2(Vector2.ZERO, size)
			for i in 5:
				DmHudKit.outline(self, r.grow(1.0 + i * 2.0), Color(DmUi.GOLD, 0.55 * (1.0 - i / 5.0) * 0.4), 2.0)


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
