class_name DmHudMinimap
extends Control
## `.hud-map .frame` + src/ui/Minimap.ts: a 190 px circular north-up map centred on the player.
## Fed with a "minimap" Dictionary (README: "minimap"); the draw order and colours are Minimap.ts line for line.

const MAP_SIZE := 190.0
const SCALE := 2.1   ## minimapCoordinates.ts MINIMAP_SCALE (px per world unit)

signal navigate(x: float, z: float)

var m: Dictionary = {}
var _t: float = 0.0
var _mask: _Circle


func _init() -> void:
	custom_minimum_size = Vector2(MAP_SIZE + 4, MAP_SIZE + 4)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Click unlocked ground to walk there"
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# the circular clip: a child that draws the disc and clips what it contains
	_mask = _Circle.new()
	add_child(_mask)


func apply(map: Dictionary) -> void:
	m = map
	_mask.m = map
	_mask.get_child(0).queue_redraw()
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	_mask._t = _t
	if m.get("ping") != null:
		_mask.get_child(0).queue_redraw()


func _draw() -> void:
	# `.frame`: 2px #1c1822 border, 1px strong, 6px #0b090e, 7px border, shadow
	var c := Vector2(size.x, size.y) * 0.5
	var r := MAP_SIZE * 0.5 + 2.0
	draw_circle(c, r + 7.0, DmUi.BORDER)
	draw_circle(c, r + 6.0, Color("0b090e"))
	draw_circle(c, r + 1.0, DmUi.BORDER_STRONG)
	draw_circle(c, r, Color("1c1822"))


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT and not m.is_empty():
		var p: Vector2 = (e.position - _mask.position) - Vector2(MAP_SIZE, MAP_SIZE) * 0.5
		if p.length() > MAP_SIZE * 0.5:
			return
		var w: Vector2 = Vector2(float(m.get("px", 0.0)), float(m.get("pz", 0.0))) + p / SCALE
		if walkable(w.x, w.y, m):
			navigate.emit(w.x, w.y)
		accept_event()


## minimapWalkable(): inside an unlocked area rect or an open door corridor.
static func walkable(x: float, z: float, map: Dictionary) -> bool:
	for a in map.get("areas", []):
		if bool(a.get("instance", false)) or not bool(a.get("unlocked", false)):
			continue
		if _inside(a["rect"], x, z):
			return true
	for d in map.get("doors", []):
		if bool(d.get("open", false)) and _inside(d["rect"], x, z):
			return true
	return false


static func _inside(r: Dictionary, x: float, z: float) -> bool:
	return x >= float(r["x0"]) and x <= float(r["x1"]) and z >= float(r["z0"]) and z <= float(r["z1"])


## The point under a click, like minimapWorldPoint(): `local` is relative to the 190 px disc's top-left.
static func world_point(local: Vector2, px: float, pz: float) -> Variant:
	var d := local - Vector2(MAP_SIZE, MAP_SIZE) * 0.5
	if d.length_squared() > (MAP_SIZE * 0.5) * (MAP_SIZE * 0.5):
		return null
	return Vector2(px + d.x / SCALE, pz + d.y / SCALE)


class _Circle extends Control:
	var m: Dictionary = {}
	var _t: float = 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(MAP_SIZE, MAP_SIZE)
		size = Vector2(MAP_SIZE, MAP_SIZE)
		position = Vector2(2, 2)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
		var inner := _Map.new()
		inner.owner_circle = self
		add_child(inner)

	func _draw() -> void:
		draw_circle(Vector2(MAP_SIZE, MAP_SIZE) * 0.5, MAP_SIZE * 0.5, Color("07060a"))


class _Map extends Control:
	var owner_circle: _Circle

	func _init() -> void:
		size = Vector2(MAP_SIZE, MAP_SIZE)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_d: float) -> void:
		pass

	func _draw() -> void:
		if owner_circle == null or owner_circle.m.is_empty():
			return
		var f: Dictionary = owner_circle.m
		var px := float(f.get("px", 0.0))
		var pz := float(f.get("pz", 0.0))
		var half := MAP_SIZE * 0.5
		var tx := func(x: float) -> float: return half + (x - px) * SCALE
		var tz := func(z: float) -> float: return half + (z - pz) * SCALE
		draw_rect(Rect2(0, 0, MAP_SIZE, MAP_SIZE), Color("07060a"))
		# areas (+ hatch for sealed ones)
		for a in f.get("areas", []):
			if bool(a.get("instance", false)):
				continue
			var r: Dictionary = a["rect"]
			var open := bool(a.get("unlocked", false))
			var safe := bool(a.get("safe", false))
			var rc := Rect2(tx.call(float(r["x0"])), tz.call(float(r["z0"])), (float(r["x1"]) - float(r["x0"])) * SCALE, (float(r["z1"]) - float(r["z0"])) * SCALE)
			draw_rect(rc, Color("2a2233") if open and safe else (Color("231d2b") if open else Color("110e15")))
			draw_rect(Rect2(rc.position + Vector2(0.5, 0.5), rc.size), Color(0.8471, 0.8118, 0.7412, 0.45 if open else 0.12), false, 1.0)
			if not open:
				var k := -400.0
				while k < 400.0:
					var p0 := Vector2(rc.position.x + k, rc.position.y)
					var p1 := p0 + Vector2(200, 200)
					var seg = _clip_line(p0, p1, rc)
					if seg != null:
						draw_line(seg[0], seg[1], Color(0.608, 0.361, 1.0, 0.12), 1.0)
					k += 8.0
		for d in f.get("doors", []):
			var r2: Dictionary = d["rect"]
			draw_rect(Rect2(tx.call(float(r2["x0"])), tz.call(float(r2["z0"])), (float(r2["x1"]) - float(r2["x0"])) * SCALE, (float(r2["z1"]) - float(r2["z0"])) * SCALE), Color("2a2233") if bool(d.get("open", false)) else Color("3b1d5e"))
		if f.get("depths") != null:
			_draw_depths(f["depths"], tx, tz)
		for w in f.get("waystones", []):
			draw_rect(Rect2(tx.call(float(w["x"])) - 2, tz.call(float(w["z"])) - 3, 4, 6), Color("9b5cff"))
		for st in f.get("stairs", []):
			var sx: float = tx.call(float(st["x"]))
			var sz: float = tz.call(float(st["z"]))
			if Vector2(sx - half, sz - half).length() > half - 3.0:
				continue
			_tri(PackedVector2Array([Vector2(sx - 4, sz - 3), Vector2(sx + 4, sz - 3), Vector2(sx, sz + 4)]), Color("ffb347"))
		for p in f.get("npcs", []):
			var sx2: float = tx.call(float(p["x"]))
			var sz2: float = tz.call(float(p["z"]))
			if Vector2(sx2 - half, sz2 - half).length() > half - 3.0:
				continue
			_tri(PackedVector2Array([Vector2(sx2, sz2 - 4.5), Vector2(sx2 + 3.5, sz2), Vector2(sx2, sz2 + 4.5), Vector2(sx2 - 3.5, sz2)]), Color("f5dd8f") if bool(p.get("fresh", false)) else Color("c9a85a"))
		for k2 in f.get("corpses", []):
			_dot(k2, 1.2, Color(0.8471, 0.8118, 0.7412, 0.35), tx, tz)
		for e in f.get("enemies", []):
			var el := bool(e.get("elite", false))
			_dot(e, 3.0 if el else 1.8, Color("c6a4ff") if el else Color("c9b9a0"), tx, tz)
		for t in f.get("thralls", []):
			_dot(t, 2.0, Color("6fe3c8"), tx, tz)
		for a2 in f.get("allies", []):
			_dot(a2, 3.0, Color("8f9ed1"), tx, tz)
		if f.get("boss") != null:
			_dot(f["boss"], 5.0, Color("7c3aed"), tx, tz)
			_dot(f["boss"], 2.5, Color("f0e9dc"), tx, tz)
		if f.get("destination") != null:
			var dd: Dictionary = f["destination"]
			var x: float = tx.call(float(dd["x"]))
			var z: float = tz.call(float(dd["z"]))
			var col := Color("e6cc91")
			draw_arc(Vector2(x, z), 4.0, 0.0, TAU, 16, col, 1.5, true)
			draw_line(Vector2(x - 6, z), Vector2(x + 6, z), col, 1.5)
			draw_line(Vector2(x, z - 6), Vector2(x, z + 6), col, 1.5)
		if f.get("ping") != null:
			var pg: Dictionary = f["ping"]
			_ping(float(pg["x"]) - px, float(pg["z"]) - pz, half)
		# player arrow: rotate(-facing + PI)
		var rot := -float(f.get("facing", 0.0)) + PI
		var pts := PackedVector2Array([Vector2(0, -7), Vector2(5, 5), Vector2(0, 2.5), Vector2(-5, 5)])
		for i in pts.size():
			pts[i] = Vector2(half, half) + pts[i].rotated(rot)
		_tri(pts, Color("c6a4ff"))
		# vignette edge: radial 0.72*half -> half, transparent -> 0.9 #07060a
		var rings := 14
		for i in rings:
			var t0 := float(i) / rings
			var r0 := half * (0.72 + 0.28 * t0)
			draw_arc(Vector2(half, half), r0 + half * 0.28 / rings * 0.5, 0.0, TAU, 64, Color(0.0275, 0.0235, 0.0392, 0.9 * (t0 + 0.5 / rings)), half * 0.28 / rings + 1.0, true)

	func _tri(pts: PackedVector2Array, fill: Color) -> void:
		draw_colored_polygon(pts, fill)
		var closed := pts.duplicate()
		closed.append(pts[0])
		draw_polyline(closed, Color("07060a"), 1.0, true)

	func _dot(o: Dictionary, r: float, col: Color, tx: Callable, tz: Callable) -> void:
		var sx: float = tx.call(float(o["x"]))
		var sz: float = tz.call(float(o["z"]))
		if sx < -4 or sz < -4 or sx > MAP_SIZE + 4 or sz > MAP_SIZE + 4:
			return
		draw_circle(Vector2(sx, sz), r, col)

	func _ping(dx: float, dz: float, half: float) -> void:
		var pulse := 0.5 + 0.5 * sin(owner_circle._t * 1000.0 / 380.0)
		var px := dx * SCALE
		var pz := dz * SCALE
		var d := sqrt(px * px + pz * pz)
		var col := Color("f5dd8f")
		if d < half - 10.0:
			var c := Vector2(half + px, half + pz)
			draw_arc(c, 6.0 + 3.0 * pulse, 0.0, TAU, 24, Color(col, 0.55 + 0.4 * pulse), 2.0, true)
			draw_circle(c, 2.0, Color(col, 0.55 + 0.4 * pulse))
		else:
			var ang := atan2(pz, px)
			var o := Vector2(half, half) + Vector2(cos(ang), sin(ang)) * (half - 9.0)
			var pts := PackedVector2Array([Vector2(6, 0), Vector2(-4, -5), Vector2(-1.5, 0), Vector2(-4, 5)])
			for i in pts.size():
				pts[i] = o + pts[i].rotated(ang)
			draw_colored_polygon(pts, Color(col, 0.7 + 0.3 * pulse))
			var closed := pts.duplicate()
			closed.append(pts[0])
			draw_polyline(closed, Color("07060a"), 1.5, true)

	func _draw_depths(d: Dictionary, tx: Callable, tz: Callable) -> void:
		for r in d.get("rooms", []):
			if not bool(r.get("active", true)):
				continue
			var rc := Rect2(tx.call(float(r["x0"])), tz.call(float(r["z0"])), (float(r["x1"]) - float(r["x0"])) * SCALE, (float(r["z1"]) - float(r["z0"])) * SCALE)
			draw_rect(rc, Color("231d2b"))
			draw_rect(Rect2(rc.position + Vector2(0.5, 0.5), rc.size), Color(0.8471, 0.8118, 0.7412, 0.45), false, 1.0)
		for door in d.get("doors", []):
			var w := 4.6 * SCALE
			var t := 3.2 * SCALE
			var x: float = tx.call(float(door["x"]))
			var z: float = tz.call(float(door["z"]))
			if String(door.get("wall", "x")) == "x":
				draw_rect(Rect2(x - t / 2, z - w / 2, t, w), Color("2a2233"))
			else:
				draw_rect(Rect2(x - w / 2, z - t / 2, w, t), Color("2a2233"))
		_mark(d["up"], Color("8fb8d8"), "up", tx, tz)
		_mark(d["down"], Color("ffb347") if bool(d["down"].get("open", false)) else Color("6a4a6a"), "down", tx, tz)
		if d.get("chest") != null:
			_mark(d["chest"], Color("f3d27a"), "box", tx, tz)

	func _mark(o: Dictionary, col: Color, shape: String, tx: Callable, tz: Callable) -> void:
		var sx: float = tx.call(float(o["x"]))
		var sz: float = tz.call(float(o["z"]))
		match shape:
			"box": _tri(PackedVector2Array([Vector2(sx - 3.5, sz - 3), Vector2(sx + 3.5, sz - 3), Vector2(sx + 3.5, sz + 3), Vector2(sx - 3.5, sz + 3)]), col)
			"down": _tri(PackedVector2Array([Vector2(sx - 5, sz - 4), Vector2(sx + 5, sz - 4), Vector2(sx, sz + 5)]), col)
			_: _tri(PackedVector2Array([Vector2(sx - 5, sz + 4), Vector2(sx + 5, sz + 4), Vector2(sx, sz - 5)]), col)

	## Liang-Barsky clip of a segment to a rect; null when outside.
	func _clip_line(a: Vector2, b: Vector2, r: Rect2) -> Variant:
		var t0 := 0.0
		var t1 := 1.0
		var dx := b.x - a.x
		var dy := b.y - a.y
		var ps := [-dx, dx, -dy, dy]
		var qs := [a.x - r.position.x, r.end.x - a.x, a.y - r.position.y, r.end.y - a.y]
		for i in 4:
			if ps[i] == 0.0:
				if qs[i] < 0.0:
					return null
			else:
				var t: float = qs[i] / ps[i]
				if ps[i] < 0.0:
					if t > t1:
						return null
					t0 = maxf(t0, t)
				else:
					if t < t0:
						return null
					t1 = minf(t1, t)
		return [a + (b - a) * t0, a + (b - a) * t1]
