class_name DmHudOrb
extends Control
## `.hud-orb`: 118 px liquid orb (health violet-plum, resource indigo, or recoloured by the class family's resource colour),
## a rippling surface, a glossy highlight, an optional bone "barrier" ring and the gold beat-pulse ring.
## Set `fill` (0..1) and the colours; `label` below is a separate node (see DmHudOrbWrap).

const SIZE := 118.0
const LIQUID_HP := [Color("7a2f63"), Color("3b0f2c"), Color("22061a")]
const SURFACE_HP := Color("a2467f")
const LIQUID_ESS := [Color("5d58d6"), Color("2a1f84"), Color("150c4a")]
const SURFACE_ESS := Color("8a82ff")

var fill: float = 1.0: set = set_fill
var liquid: Array = LIQUID_HP
var surface: Color = SURFACE_HP
var barrier: float = 0.0: set = set_barrier   ## 0..0.9 alpha of the bone ring (web: min(0.9, barrier/maxHp*3))
var beat_pulse: bool = false: set = set_beat
var _shown_fill: float = 1.0
var _t: float = 0.0
var _since_draw: float = 0.0


func _init() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_fill(v: float) -> void:
	fill = clampf(v, 0.0, 1.0)


func set_barrier(v: float) -> void:
	barrier = clampf(v, 0.0, 0.9)
	queue_redraw()


func set_beat(b: bool) -> void:
	beat_pulse = b
	scale = Vector2.ONE * (1.07 if b else 1.0)
	pivot_offset = Vector2(SIZE, SIZE) * 0.5
	queue_redraw()


## From a "#rrggbb" resource colour (resources.ts): liquid = res -> res 55% over #0b0810 -> #0b0810, surface = res 70% over white.
func set_resource_color(c: Color) -> void:
	var dark := Color("0b0810")
	if liquid.size() == 3 and (liquid[0] as Color) == c and (liquid[2] as Color) == dark:
		return   # applied with every vitals change; an unchanged colour repaints nothing
	liquid = [c, c.lerp(dark, 0.45), dark]
	surface = c.lerp(Color.WHITE, 0.3)
	_palette_changed()


func _palette_changed() -> void:
	queue_redraw()
	if _under != null:
		_under.queue_redraw()


func use_health_palette() -> void:
	if liquid == LIQUID_HP:
		return
	liquid = LIQUID_HP
	surface = SURFACE_HP
	_palette_changed()


func use_resource_palette() -> void:
	if liquid == LIQUID_ESS:
		return
	liquid = LIQUID_ESS
	surface = SURFACE_ESS
	_palette_changed()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_ENTER_TREE:
		set_process(is_visible_in_tree())   # a hidden HUD animates nothing


func _process(delta: float) -> void:
	_t += delta
	# `transition: height 0.18s ease-out`
	var easing := not is_equal_approx(_shown_fill, fill)
	if not easing and _shown_fill <= 0.002 and not beat_pulse:
		return   # an empty settled orb has no ripple; its other changes queue their own redraw
	_shown_fill = move_toward(_shown_fill, fill, delta * maxf(1.0, absf(fill - _shown_fill)) / 0.18)
	if easing and _under != null:
		_under.queue_redraw()   # the liquid body follows the shown fill
	# The surface ripple has a 3.5 s period: 30 Hz is indistinguishable from every frame, so a settled orb redraws at 30 Hz, an easing one every frame.
	_since_draw += delta
	if easing or _since_draw >= 0.03:
		_since_draw = 0.0
		queue_redraw()


## Static art in two never-redrawing-on-their-own children: the dish (rings, bowl) behind the orb and the gloss in front. The liquid body is
## the "under" layer too and repaints only when the shown fill or the palette changes; this node paints the moving ripple, barrier and beat rings.
class _Layer extends Control:
	var orb: DmHudOrb
	var kind := 0   ## 0 = dish + liquid body (behind), 1 = gloss (in front)

	func _init(o: DmHudOrb, k: int) -> void:
		orb = o
		kind = k
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		show_behind_parent = k == 0
		size = Vector2(DmHudOrb.SIZE, DmHudOrb.SIZE)

	func _draw() -> void:
		if kind == 0:
			orb._draw_dish()
			orb._draw_body(self)
		else:
			orb._draw_gloss(self)


var _under: _Layer
var _gloss: _Layer


func _ready() -> void:
	_under = _Layer.new(self, 0)
	add_child(_under)
	_gloss = _Layer.new(self, 1)
	add_child(_gloss)


func _geo_top(ri: float, f: float) -> float:
	return SIZE * 0.5 + ri - f * 2.0 * ri


func _draw_dish() -> void:
	var c := Vector2(SIZE, SIZE) * 0.5
	var r := SIZE * 0.5
	var u := _under
	# rings: 0 0 0 6px (bone 20%), 5px #0b090e, 1px (bone 40%)
	u.draw_circle(c, r + 6.0, Color(DmUi.BONE_300, 0.20))
	u.draw_circle(c, r + 5.0, Color("0b090e"))
	u.draw_circle(c, r + 1.0, Color(DmUi.BONE_300, 0.40))
	u.draw_circle(c, r, Color("1a1620"))               # 3px border
	var ri := r - 3.0
	u.draw_circle(c, ri, Color("050407"))
	u.draw_circle(c, ri * 0.72, Color("0b0910"))        # radial-gradient(circle at 50% 40%, #1a1420, #050407 72%)
	u.draw_circle(c + Vector2(0, -ri * 0.2), ri * 0.4, Color("120e17"))


func _draw_body(u: Control) -> void:
	var f := _shown_fill
	if f <= 0.002:
		return
	var c := Vector2(SIZE, SIZE) * 0.5
	var ri := SIZE * 0.5 - 3.0
	var top := _geo_top(ri, f)
	var dy := clampf((top - c.y) / ri, -1.0, 1.0)
	var a0 := asin(dy)
	var a1 := PI - a0
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var steps := 40
	var bottom := c.y + ri
	for i in steps + 1:
		var a := a0 + (a1 - a0) * float(i) / steps
		var p := c + Vector2(cos(a), sin(a)) * ri
		pts.append(p)
		cols.append(_grad((p.y - top) / maxf(bottom - top, 1.0)))
	u.draw_polygon(pts, cols)


func _draw_gloss(g_: Control) -> void:
	# gloss: radial-gradient(circle at 34% 26%, white 28%..transparent 26%) + dark under-glow
	var g := Vector2(SIZE * 0.34, SIZE * 0.26)
	for i in 6:
		g_.draw_circle(g, SIZE * 0.26 * (1.0 - i / 6.0), Color(1, 1, 1, 0.045))


func _draw() -> void:
	var c := Vector2(SIZE, SIZE) * 0.5
	var r := SIZE * 0.5
	var ri := r - 3.0
	var f := _shown_fill
	if f > 0.002:
		# the rippling surface: a band of scallops along the liquid line (orb-wave, 3.5 s, 34 px period)
		var top := _geo_top(ri, f)
		var band := PackedVector2Array()
		var x0 := c.x - ri
		var n := 48
		for i in n + 1:
			var x := x0 + 2.0 * ri * float(i) / n
			var y := top - 3.0 - 3.0 * (0.5 + 0.5 * sin((x - c.x) / 34.0 * TAU + _t / 3.5 * TAU))
			if absf(x - c.x) <= ri * cos(asin(clampf((y - c.y) / ri, -1, 1))):
				band.append(Vector2(x, y))
		if band.size() > 1:
			draw_polyline(band, Color(surface, 0.8), 2.0, true)
	# barrier ring (inset 4px bone)
	if barrier > 0.0:
		draw_arc(c, ri - 2.0, 0.0, TAU, 48, Color(DmUi.BONE_300, barrier), 4.0, true)
	if beat_pulse:
		draw_arc(c, r + 1.5, 0.0, TAU, 64, Color(0.9, 0.827, 0.545, 0.72), 3.0, true)
		draw_arc(c, r + 5.0, 0.0, TAU, 64, Color(0.9, 0.827, 0.545, 0.25), 6.0, true)


func _grad(t: float) -> Color:
	t = clampf(t, 0.0, 1.0)
	if t < 0.7:
		return (liquid[0] as Color).lerp(liquid[1], t / 0.7)
	return (liquid[1] as Color).lerp(liquid[2], (t - 0.7) / 0.3)
