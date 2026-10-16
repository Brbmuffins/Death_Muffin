class_name DmHudOrb
extends Control
## `.hud-orb`: 118 px liquid orb (health violet-plum, resource indigo, or recoloured by the class family's resource colour),
## a rippling surface, a glossy highlight, an optional bone "barrier" ring and the gold beat-pulse ring.
## Set `fill` (0..1) and the colours; `label` below is a separate node (see DmHudOrbWrap).
## Ported (client/code.list): the orb is two triangle meshes, one behind (the dish, its rings, and the liquid body) and one in front (the ripple, the barrier and
## beat rings, the gloss), so it costs two draw calls where it was drawn with sixteen circles, a polygon and three polylines. Same shapes, same colours.

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
var _drawn_fill: float = -1.0   ## the fill the body was last built for
var _t: float = 0.0
var _since_draw: float = 0.0
var _grad_tab := PackedColorArray()   ## the liquid's gradient in 33 steps, rebuilt with the palette

const BODY_STEPS := 20          ## segments of the liquid's lower arc (a 9 degree chord is 0.2 px off the circle at this radius)
const RIPPLE_POINTS := 33       ## samples along the liquid line (3.5 px apart: ten to a 34 px wave)
const RIPPLE_HZ := 15.0         ## the surface moves 10 px a second, so 15 redraws a second are 0.65 px apart

static var _dish: DmHudMesh     ## the rings and the bowl: never change, built once
static var _gloss: DmHudMesh    ## the highlight: never changes, built once
static var _rib_idx: PackedInt32Array   ## the triangles of a ribbon through RIPPLE_POINTS samples (a shorter one uses the start of it)
static var _rib_phase: PackedFloat32Array   ## per sample: its phase in the wave at t = 0
static var _rib_dx: PackedFloat32Array      ## per sample: its x from the orb's centre


func _init() -> void:
	z_index = DmHudKit.Z_ART
	custom_minimum_size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_fill(v: float) -> void:
	fill = clampf(v, 0.0, 1.0)


func set_barrier(v: float) -> void:
	var b := clampf(v, 0.0, 0.9)
	if is_equal_approx(b, barrier):
		return
	barrier = b
	_redraw_front()


func set_beat(b: bool) -> void:
	if b == beat_pulse:
		return
	beat_pulse = b
	scale = Vector2.ONE * (1.07 if b else 1.0)
	pivot_offset = Vector2(SIZE, SIZE) * 0.5
	_redraw_front()


## From a "#rrggbb" resource colour (resources.ts): liquid = res -> res 55% over #0b0810 -> #0b0810, surface = res 70% over white.
func set_resource_color(c: Color) -> void:
	var dark := Color("0b0810")
	if liquid.size() == 3 and (liquid[0] as Color) == c and (liquid[2] as Color) == dark:
		return   # applied with every vitals change; an unchanged colour repaints nothing
	liquid = [c, c.lerp(dark, 0.45), dark]
	surface = c.lerp(Color.WHITE, 0.3)
	_palette_changed()


func _palette_changed() -> void:
	_grad_tab.clear()
	_redraw_front()
	_drawn_fill = -1.0
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
	# the liquid body follows the shown fill: rebuilt when it moved half a pixel or more (118 px orb), and at the end of the move
	if _under != null and (absf(_shown_fill - _drawn_fill) >= 0.004 or (not easing and _shown_fill != _drawn_fill)):
		_drawn_fill = _shown_fill
		_under.queue_redraw()
	# The surface ripple has a 3.5 s period and moves 10 px a second: a settled orb redraws it RIPPLE_HZ times a second, an easing one with every frame.
	_since_draw += delta
	if easing or _since_draw >= 1.0 / RIPPLE_HZ:
		_since_draw = 0.0
		_redraw_front()


func _redraw_front() -> void:
	if _front != null:
		_front.queue_redraw()


## The two meshes, in two never-drawing-on-their-own children: behind the orb (the dish and the liquid body: repainted when the shown fill or the palette changes)
## and in front of it (the ripple, rings and gloss: repainted by the 30 Hz ripple).
class _Layer extends Control:
	var orb: DmHudOrb
	var kind := 0   ## 0 = dish + liquid body (behind), 1 = ripple, rings and gloss (in front)
	var mesh := DmHudMesh.new()

	func _init(o: DmHudOrb, k: int) -> void:
		orb = o
		kind = k
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		show_behind_parent = k == 0
		size = Vector2(DmHudOrb.SIZE, DmHudOrb.SIZE)

	func _draw() -> void:
		mesh.clear()
		if kind == 0:
			orb._build_under(mesh)
		else:
			orb._build_front(mesh)
		mesh.submit(self)


var _under: _Layer
var _front: _Layer


func _ready() -> void:
	_under = _Layer.new(self, 0)
	add_child(_under)
	_front = _Layer.new(self, 1)
	add_child(_front)


func _geo_top(ri: float, f: float) -> float:
	return SIZE * 0.5 + ri - f * 2.0 * ri


## Dish and body. The dish (rings, bowl) is a mesh of seven discs built once; the body is the circular segment under the liquid line, as horizontal bands.
func _build_under(m: DmHudMesh) -> void:
	if _dish == null:
		var c := Vector2(SIZE, SIZE) * 0.5
		var r := SIZE * 0.5
		var d := DmHudMesh.new()
		# rings: 0 0 0 6px (bone 20%), 5px #0b090e, 1px (bone 40%)
		d.disc(c, r + 6.0, Color(DmUi.BONE_300, 0.20))
		d.disc(c, r + 5.0, Color("0b090e"))
		d.disc(c, r + 1.0, Color(DmUi.BONE_300, 0.40))
		d.disc(c, r, Color("1a1620"))               # 3px border
		var ri0 := r - 3.0
		d.disc(c, ri0, Color("050407"))
		d.disc(c, ri0 * 0.72, Color("0b0910"))        # radial-gradient(circle at 50% 40%, #1a1420, #050407 72%)
		d.disc(c + Vector2(0, -ri0 * 0.2), ri0 * 0.4, Color("120e17"))
		_dish = d
	m.append(_dish)
	var f := _shown_fill
	if f <= 0.002:
		return
	var c2 := Vector2(SIZE, SIZE) * 0.5
	var ri := SIZE * 0.5 - 3.0
	var top := _geo_top(ri, f)
	var dy := clampf((top - c2.y) / ri, -1.0, 1.0)
	var a0 := asin(dy)
	var a1 := PI - a0
	var bottom := c2.y + ri
	var inv_span := 1.0 / maxf(bottom - top, 1.0)
	if _grad_tab.is_empty():
		_grad_tab.resize(33)
		for i in 33:
			_grad_tab[i] = _grad(float(i) / 32.0)
	# the arc from the right end of the liquid line round the bottom to its left end; point i and point STEPS-i share a height: one rung of a ladder
	var first := m.pts.size()
	var n := BODY_STEPS + 1
	m.pts.resize(first + n)
	m.cols.resize(first + n)
	var da := (a1 - a0) / BODY_STEPS
	for i in n:
		var a := a0 + da * i
		var p := Vector2(c2.x + cos(a) * ri, c2.y + sin(a) * ri)
		m.pts[first + i] = p
		m.cols[first + i] = _grad_tab[clampi(roundi((p.y - top) * inv_span * 32.0), 0, 32)]
	for i in BODY_STEPS / 2:
		var r0 := first + i
		var l0 := first + BODY_STEPS - i
		var r1 := r0 + 1
		var l1 := l0 - 1
		m.idx.append(r0)
		m.idx.append(r1)
		m.idx.append(l1)
		m.idx.append(r0)
		m.idx.append(l1)
		m.idx.append(l0)


## Ripple, rings, gloss.
func _build_front(m: DmHudMesh) -> void:
	var c := Vector2(SIZE, SIZE) * 0.5
	var r := SIZE * 0.5
	var ri := r - 3.0
	var f := _shown_fill
	if f > 0.002:
		_ripple(m, c, ri, _geo_top(ri, f))
	# barrier ring (inset 4px bone)
	if barrier > 0.0:
		m.ring(c, ri - 4.0, ri, Color(DmUi.BONE_300, barrier), 48)
	if beat_pulse:
		m.ring(c, r, r + 3.0, Color(0.9, 0.827, 0.545, 0.72))
		m.ring(c, r + 2.0, r + 8.0, Color(0.9, 0.827, 0.545, 0.25))
	if _gloss == null:
		# gloss: radial-gradient(circle at 34% 26%, white 28%..transparent 26%) + dark under-glow
		var g := DmHudMesh.new()
		var gc := Vector2(SIZE * 0.34, SIZE * 0.26)
		for i in 6:
			g.disc(gc, SIZE * 0.26 * (1.0 - i / 6.0), Color(1, 1, 1, 0.045))
		_gloss = g
	m.append(_gloss)


## The rippling surface: a band of scallops along the liquid line (orb-wave, 3.5 s, 34 px period), a 2 px line with a feathered edge (the anti-aliased polyline it was), as
## one strip of triangles. The samples inside the dish are a run: the strip starts the mesh, so its triangles are the preset ones.
func _ripple(m: DmHudMesh, c: Vector2, ri: float, top: float) -> void:
	if _rib_idx.is_empty():
		_rib_idx.resize((RIPPLE_POINTS - 1) * 18)
		_rib_phase.resize(RIPPLE_POINTS)
		_rib_dx.resize(RIPPLE_POINTS)
		var k := 0
		for i in RIPPLE_POINTS - 1:
			var a := i * 4
			var b := a + 4
			for q in 3:
				_rib_idx[k] = a + q
				_rib_idx[k + 1] = a + q + 1
				_rib_idx[k + 2] = b + q + 1
				_rib_idx[k + 3] = a + q
				_rib_idx[k + 4] = b + q + 1
				_rib_idx[k + 5] = b + q
				k += 6
		for i in RIPPLE_POINTS:
			_rib_dx[i] = -ri + 2.0 * ri * float(i) / (RIPPLE_POINTS - 1)
			_rib_phase[i] = _rib_dx[i] / 34.0 * TAU
	var w := _t / 3.5 * TAU
	var col := Color(surface, 0.8)
	var clear := Color(surface, 0.0)
	var slope := 1.5 * TAU / 34.0   # |dy/dx| of the wave
	var ri2 := ri * ri
	var n := 0
	m.pts.resize(RIPPLE_POINTS * 4)
	m.cols.resize(RIPPLE_POINTS * 4)
	for i in RIPPLE_POINTS:
		var th := _rib_phase[i] + w
		var y := top - 3.0 - 3.0 * (0.5 + 0.5 * sin(th)) - c.y
		var dx := _rib_dx[i]
		if dx * dx + y * y > ri2:
			if n > 0:
				break   # past the far edge of the dish
			continue    # not yet inside it
		var d := Vector2(1.0, -slope * cos(th))   # the line's direction (y' = -1.5 TAU/34 cos)
		var nrm := Vector2(-d.y, d.x) / d.length()
		var p := Vector2(c.x + dx, c.y + y)
		var o := n * 4
		m.pts[o] = p + nrm * 1.5
		m.pts[o + 1] = p + nrm
		m.pts[o + 2] = p - nrm
		m.pts[o + 3] = p - nrm * 1.5
		m.cols[o] = clear
		m.cols[o + 1] = col
		m.cols[o + 2] = col
		m.cols[o + 3] = clear
		n += 1
	m.pts.resize(n * 4)
	m.cols.resize(n * 4)
	if n > 1:
		m.idx.append_array(_rib_idx.slice(0, (n - 1) * 18))
	else:
		m.pts.resize(0)
		m.cols.resize(0)


func _grad(t: float) -> Color:
	t = clampf(t, 0.0, 1.0)
	if t < 0.7:
		return (liquid[0] as Color).lerp(liquid[1], t / 0.7)
	return (liquid[1] as Color).lerp(liquid[2], (t - 0.7) / 0.3)
