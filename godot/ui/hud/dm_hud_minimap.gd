class_name DmHudMinimap
extends Control
## `.hud-map .frame` + archive/legacy-web:src/ui/Minimap.ts: a 190 px circular north-up map centred on the player.
## Fed with a "minimap" Dictionary (README: "minimap"); the draw order and colours are Minimap.ts line for line.

const MAP_SIZE := 190.0
const SCALE := 2.1   ## minimapCoordinates.ts MINIMAP_SCALE (px per world unit)

## Palette (Minimap.ts), parsed once.
const C_VOID := Color("07060a")
const C_AREA_SAFE := Color("2a2233")
const C_AREA_OPEN := Color("231d2b")
const C_AREA_SEALED := Color("110e15")
const C_AREA_EDGE_OPEN := Color(0.8471, 0.8118, 0.7412, 0.45)
const C_AREA_EDGE_SEALED := Color(0.8471, 0.8118, 0.7412, 0.12)
const C_HATCH := Color(0.608, 0.361, 1.0, 0.12)
const C_DOOR_SEALED := Color("3b1d5e")
const C_WAYSTONE := Color("9b5cff")
const C_STAIRS := Color("ffb347")
const C_NPC_FRESH := Color("f5dd8f")
const C_NPC := Color("c9a85a")
const C_CORPSE := Color(0.8471, 0.8118, 0.7412, 0.35)
const C_ELITE := Color("c6a4ff")
const C_ENEMY := Color("c9b9a0")
const C_THRALL := Color("6fe3c8")
const C_ALLY := Color("8f9ed1")
const C_BOSS := Color("7c3aed")
const C_BOSS_CORE := Color("f0e9dc")
const C_DEST := Color("e6cc91")
const C_PING := Color("f5dd8f")
const C_PLAYER := Color("c6a4ff")
const C_DEPTH_UP := Color("8fb8d8")
const C_DEPTH_DOWN_OPEN := Color("ffb347")
const C_DEPTH_DOWN := Color("6a4a6a")
const C_DEPTH_CHEST := Color("f3d27a")
const C_FRAME_BORDER := Color("0b090e")
const C_FRAME_INNER := Color("1c1822")

signal navigate(x: float, z: float)

var m: Dictionary = {}
var _t: float = 0.0
var _mask: _Circle


func _init() -> void:
	custom_minimum_size = Vector2(MAP_SIZE + 4, MAP_SIZE + 4)
	set_process(false)
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
	# the pulse of a guidance ping is the only thing that animates between refreshes
	set_process(map.get("ping") != null)


func _process(delta: float) -> void:
	_t += delta
	_mask._t = _t
	_mask.get_child(0).queue_redraw()


func _draw() -> void:
	# `.frame`: 2px #1c1822 border, 1px strong, 6px #0b090e, 7px border, shadow
	var c := Vector2(size.x, size.y) * 0.5
	var r := MAP_SIZE * 0.5 + 2.0
	draw_circle(c, r + 7.0, DmUi.BORDER)
	draw_circle(c, r + 6.0, C_FRAME_BORDER)
	draw_circle(c, r + 1.0, DmUi.BORDER_STRONG)
	draw_circle(c, r, C_FRAME_INNER)


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
		add_child(_Vignette.new())   # above the dots, drawn once

	func _draw() -> void:
		draw_circle(Vector2(MAP_SIZE, MAP_SIZE) * 0.5, MAP_SIZE * 0.5, C_VOID)


## The edge fade (radial 0.72*half -> half, transparent -> 0.9 #07060a): 14 rings that never change, so drawn once, not with every refresh.
class _Vignette extends Control:
	func _init() -> void:
		size = Vector2(MAP_SIZE, MAP_SIZE)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var half := MAP_SIZE * 0.5
		var rings := 14
		for i in rings:
			var t0 := float(i) / rings
			var r0 := half * (0.72 + 0.28 * t0)
			draw_arc(Vector2(half, half), r0 + half * 0.28 / rings * 0.5, 0.0, TAU, 64, Color(0.0275, 0.0235, 0.0392, 0.9 * (t0 + 0.5 / rings)), half * 0.28 / rings + 1.0, true)


class _Map extends Control:
	var owner_circle: _Circle
	## Hatch segments of a sealed area, relative to its top-left corner, per area size (areas are fixed rects): built once, drawn as one command.
	static var _hatch := {}
	var _view := Rect2(-4, -4, MAP_SIZE + 8, MAP_SIZE + 8)

	func _init() -> void:
		size = Vector2(MAP_SIZE, MAP_SIZE)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if owner_circle == null or owner_circle.m.is_empty():
			return
		var f: Dictionary = owner_circle.m
		var px := float(f.get("px", 0.0))
		var pz := float(f.get("pz", 0.0))
		var half := MAP_SIZE * 0.5
		draw_rect(Rect2(0, 0, MAP_SIZE, MAP_SIZE), C_VOID)
		# areas (+ hatch for sealed ones); what lies outside the disc is not drawn at all
		for a in f.get("areas", []):
			if bool(a.get("instance", false)):
				continue
			var r: Dictionary = a["rect"]
			var rc := _rect(r, px, pz, half)
			if not rc.grow(2.0).intersects(_view):
				continue
			var open := bool(a.get("unlocked", false))
			var safe := bool(a.get("safe", false))
			draw_rect(rc, C_AREA_SAFE if open and safe else (C_AREA_OPEN if open else C_AREA_SEALED))
			draw_rect(Rect2(rc.position + Vector2(0.5, 0.5), rc.size), C_AREA_EDGE_OPEN if open else C_AREA_EDGE_SEALED, false, 1.0)
			if not open:
				draw_set_transform(rc.position)
				draw_multiline(_hatch_for(rc.size), C_HATCH, 1.0)
				draw_set_transform(Vector2.ZERO)
		for d in f.get("doors", []):
			var rd := _rect(d["rect"], px, pz, half)
			if rd.grow(2.0).intersects(_view):
				draw_rect(rd, C_AREA_SAFE if bool(d.get("open", false)) else C_DOOR_SEALED)
		if f.get("depths") != null:
			_draw_depths(f["depths"], px, pz, half)
		for w in f.get("waystones", []):
			draw_rect(Rect2(half + (float(w["x"]) - px) * SCALE - 2, half + (float(w["z"]) - pz) * SCALE - 3, 4, 6), C_WAYSTONE)
		for st in f.get("stairs", []):
			var sx: float = half + (float(st["x"]) - px) * SCALE
			var sz: float = half + (float(st["z"]) - pz) * SCALE
			if Vector2(sx - half, sz - half).length() > half - 3.0:
				continue
			_tri(PackedVector2Array([Vector2(sx - 4, sz - 3), Vector2(sx + 4, sz - 3), Vector2(sx, sz + 4)]), C_STAIRS)
		for p in f.get("npcs", []):
			var sx2: float = half + (float(p["x"]) - px) * SCALE
			var sz2: float = half + (float(p["z"]) - pz) * SCALE
			if Vector2(sx2 - half, sz2 - half).length() > half - 3.0:
				continue
			_tri(PackedVector2Array([Vector2(sx2, sz2 - 4.5), Vector2(sx2 + 3.5, sz2), Vector2(sx2, sz2 + 4.5), Vector2(sx2 - 3.5, sz2)]), C_NPC_FRESH if bool(p.get("fresh", false)) else C_NPC)
		for k2 in f.get("corpses", []):
			_dot(k2, 1.2, C_CORPSE, px, pz, half)
		for e in f.get("enemies", []):
			if e.get("elite", false):
				_dot(e, 3.0, C_ELITE, px, pz, half)
			else:
				_dot(e, 1.8, C_ENEMY, px, pz, half)
		for t in f.get("thralls", []):
			_dot(t, 2.0, C_THRALL, px, pz, half)
		for a2 in f.get("allies", []):
			_dot(a2, 3.0, C_ALLY, px, pz, half)
		if f.get("boss") != null:
			_dot(f["boss"], 5.0, C_BOSS, px, pz, half)
			_dot(f["boss"], 2.5, C_BOSS_CORE, px, pz, half)
		if f.get("destination") != null:
			var dd: Dictionary = f["destination"]
			var x: float = half + (float(dd["x"]) - px) * SCALE
			var z: float = half + (float(dd["z"]) - pz) * SCALE
			draw_arc(Vector2(x, z), 4.0, 0.0, TAU, 16, C_DEST, 1.5, true)
			draw_line(Vector2(x - 6, z), Vector2(x + 6, z), C_DEST, 1.5)
			draw_line(Vector2(x, z - 6), Vector2(x, z + 6), C_DEST, 1.5)
		if f.get("ping") != null:
			var pg: Dictionary = f["ping"]
			_ping(float(pg["x"]) - px, float(pg["z"]) - pz, half)
		# player arrow: rotate(-facing + PI)
		var rot := -float(f.get("facing", 0.0)) + PI
		var pts := PackedVector2Array([Vector2(0, -7), Vector2(5, 5), Vector2(0, 2.5), Vector2(-5, 5)])
		for i in pts.size():
			pts[i] = Vector2(half, half) + pts[i].rotated(rot)
		_tri(pts, C_PLAYER)
		# (the edge vignette is the static _Vignette layer above this one)

	## A world rect ({x0, z0, x1, z1}) in map pixels.
	static func _rect(r: Dictionary, px: float, pz: float, half: float) -> Rect2:
		var x0 := float(r["x0"])
		var z0 := float(r["z0"])
		return Rect2(half + (x0 - px) * SCALE, half + (z0 - pz) * SCALE, (float(r["x1"]) - x0) * SCALE, (float(r["z1"]) - z0) * SCALE)

	## The 45 degree hatch of a sealed area of this pixel size, clipped to it: line segment pairs relative to the area's corner.
	static func _hatch_for(sz: Vector2) -> PackedVector2Array:
		var cached: Variant = _hatch.get(sz)
		if cached != null:
			return cached
		var out := PackedVector2Array()
		var clip := Rect2(Vector2.ZERO, sz)
		var k := -400.0
		while k < 400.0:
			var seg: Variant = _clip_line(Vector2(k, 0.0), Vector2(k + 200.0, 200.0), clip)
			if seg != null:
				out.append(seg[0])
				out.append(seg[1])
			k += 8.0
		_hatch[sz] = out
		return out

	func _tri(pts: PackedVector2Array, fill: Color) -> void:
		draw_colored_polygon(pts, fill)
		pts.append(pts[0])
		draw_polyline(pts, C_VOID, 1.0, true)

	func _dot(o: Dictionary, r: float, col: Color, px: float, pz: float, half: float) -> void:
		var sx: float = half + (float(o["x"]) - px) * SCALE
		var sz: float = half + (float(o["z"]) - pz) * SCALE
		if sx < -4 or sz < -4 or sx > MAP_SIZE + 4 or sz > MAP_SIZE + 4:
			return
		draw_circle(Vector2(sx, sz), r, col)

	func _ping(dx: float, dz: float, half: float) -> void:
		var pulse := 0.5 + 0.5 * sin(owner_circle._t * 1000.0 / 380.0)
		var px := dx * SCALE
		var pz := dz * SCALE
		var d := sqrt(px * px + pz * pz)
		if d < half - 10.0:
			var c := Vector2(half + px, half + pz)
			draw_arc(c, 6.0 + 3.0 * pulse, 0.0, TAU, 24, Color(C_PING, 0.55 + 0.4 * pulse), 2.0, true)
			draw_circle(c, 2.0, Color(C_PING, 0.55 + 0.4 * pulse))
		else:
			var ang := atan2(pz, px)
			var o := Vector2(half, half) + Vector2(cos(ang), sin(ang)) * (half - 9.0)
			var pts := PackedVector2Array([Vector2(6, 0), Vector2(-4, -5), Vector2(-1.5, 0), Vector2(-4, 5)])
			for i in pts.size():
				pts[i] = o + pts[i].rotated(ang)
			draw_colored_polygon(pts, Color(C_PING, 0.7 + 0.3 * pulse))
			pts.append(pts[0])
			draw_polyline(pts, C_VOID, 1.5, true)

	func _draw_depths(d: Dictionary, px: float, pz: float, half: float) -> void:
		for r in d.get("rooms", []):
			if not bool(r.get("active", true)):
				continue
			var rc := _rect(r, px, pz, half)
			draw_rect(rc, C_AREA_OPEN)
			draw_rect(Rect2(rc.position + Vector2(0.5, 0.5), rc.size), C_AREA_EDGE_OPEN, false, 1.0)
		for door in d.get("doors", []):
			var w := 4.6 * SCALE
			var t := 3.2 * SCALE
			var x: float = half + (float(door["x"]) - px) * SCALE
			var z: float = half + (float(door["z"]) - pz) * SCALE
			if String(door.get("wall", "x")) == "x":
				draw_rect(Rect2(x - t / 2, z - w / 2, t, w), C_AREA_SAFE)
			else:
				draw_rect(Rect2(x - w / 2, z - t / 2, w, t), C_AREA_SAFE)
		_mark(d["up"], C_DEPTH_UP, "up", px, pz, half)
		_mark(d["down"], C_DEPTH_DOWN_OPEN if bool(d["down"].get("open", false)) else C_DEPTH_DOWN, "down", px, pz, half)
		if d.get("chest") != null:
			_mark(d["chest"], C_DEPTH_CHEST, "box", px, pz, half)

	func _mark(o: Dictionary, col: Color, shape: String, px: float, pz: float, half: float) -> void:
		var sx: float = half + (float(o["x"]) - px) * SCALE
		var sz: float = half + (float(o["z"]) - pz) * SCALE
		match shape:
			"box": _tri(PackedVector2Array([Vector2(sx - 3.5, sz - 3), Vector2(sx + 3.5, sz - 3), Vector2(sx + 3.5, sz + 3), Vector2(sx - 3.5, sz + 3)]), col)
			"down": _tri(PackedVector2Array([Vector2(sx - 5, sz - 4), Vector2(sx + 5, sz - 4), Vector2(sx, sz + 5)]), col)
			_: _tri(PackedVector2Array([Vector2(sx - 5, sz + 4), Vector2(sx + 5, sz + 4), Vector2(sx, sz - 5)]), col)

	## Liang-Barsky clip of a segment to a rect; null when outside.
	static func _clip_line(a: Vector2, b: Vector2, r: Rect2) -> Variant:
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
