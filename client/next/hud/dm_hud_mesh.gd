class_name DmHudMesh
extends RefCounted
## A bag of coloured triangles that a HUD widget draws as ONE command (one draw call), where `draw_circle`, `draw_colored_polygon`, `draw_arc` and `draw_polyline`
## are one draw call EACH (circles, polygons and arcs never batch; client/README.md "The HUD's budget"). Build it with the shape helpers, then either
## `submit(item)` (a mesh made now, inside `_draw`) or `to_mesh()` (an ArrayMesh made once for art that never changes; draw it with `draw_mesh`).
## Triangles are drawn in the order they were added, so translucent shapes blend as separate draws would have. The arrays are reused: `clear()` keeps their memory.

const CIRCLE_SEGMENTS := 64   ## CanvasItem.draw_circle's own count: the shapes keep its outline

var pts := PackedVector2Array()
var cols := PackedColorArray()
var idx := PackedInt32Array()
var _moved: Dictionary = {}   ## first vertex -> this bag's indices moved to start there (`append`)

const MOVED_KEEP := 64   ## starts kept per bag (the orb's ripple moves the gloss's start with its point count: a few dozen)


func clear() -> void:
	pts.resize(0)
	cols.resize(0)
	idx.resize(0)
	if not _moved.is_empty():
		_moved.clear()


func is_empty() -> bool:
	return idx.is_empty()


func vertex(p: Vector2, c: Color) -> int:
	pts.append(p)
	cols.append(c)
	return pts.size() - 1


func tri(a: Vector2, b: Vector2, c: Vector2, col: Color) -> void:
	var i := pts.size()
	pts.append(a)
	pts.append(b)
	pts.append(c)
	cols.append(col)
	cols.append(col)
	cols.append(col)
	idx.append(i)
	idx.append(i + 1)
	idx.append(i + 2)


## Triangle with a colour per corner.
func tri_c(a: Vector2, ca: Color, b: Vector2, cb: Color, c: Vector2, cc: Color) -> void:
	var i := vertex(a, ca)
	vertex(b, cb)
	vertex(c, cc)
	idx.append(i)
	idx.append(i + 1)
	idx.append(i + 2)


## A quad a-b-c-d (in order around it) in one colour.
func quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, col: Color) -> void:
	var i := pts.size()
	pts.append(a)
	pts.append(b)
	pts.append(c)
	pts.append(d)
	for k in 4:
		cols.append(col)
	idx.append(i)
	idx.append(i + 1)
	idx.append(i + 2)
	idx.append(i)
	idx.append(i + 2)
	idx.append(i + 3)


func rect(r: Rect2, col: Color) -> void:
	quad(r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), col)


## Filled circle as a fan of `segs` triangles (draw_circle's own shape at the default 64).
func disc(c: Vector2, radius: float, col: Color, segs: int = CIRCLE_SEGMENTS) -> void:
	var i := vertex(c, col)
	for k in segs:
		var a := TAU * float(k) / segs
		vertex(c + Vector2(cos(a), sin(a)) * radius, col)
	for k in segs:
		idx.append(i)
		idx.append(i + 1 + k)
		idx.append(i + 1 + (k + 1) % segs)


## A ring (or an arc of it) between two radii: a strip of quads.
func ring(c: Vector2, r_in: float, r_out: float, col: Color, segs: int = CIRCLE_SEGMENTS, a0: float = 0.0, a1: float = TAU) -> void:
	var first := pts.size()
	for k in segs + 1:
		var a := a0 + (a1 - a0) * float(k) / segs
		var d := Vector2(cos(a), sin(a))
		vertex(c + d * r_in, col)
		vertex(c + d * r_out, col)
	for k in segs:
		var i := first + k * 2
		idx.append(i)
		idx.append(i + 1)
		idx.append(i + 3)
		idx.append(i)
		idx.append(i + 3)
		idx.append(i + 2)


## A line segment of the given width as a quad.
func line(a: Vector2, b: Vector2, width: float, col: Color) -> void:
	var d := b - a
	var l := d.length()
	if l <= 0.0001:
		return
	var n := Vector2(-d.y, d.x) / l * (width * 0.5)
	quad(a + n, b + n, b - n, a - n, col)


## A convex polygon, one colour (a fan from its first point).
func convex(points: PackedVector2Array, col: Color) -> void:
	if points.size() < 3:
		return
	var i := vertex(points[0], col)
	for k in range(1, points.size()):
		vertex(points[k], col)
	for k in range(1, points.size() - 1):
		idx.append(i)
		idx.append(i + k)
		idx.append(i + k + 1)


## Appends another bag's triangles (art that never changes is built once and appended to the part that does). The appended bag's indices, moved to where its
## vertices now start, are kept per start (`_moved`): the same art appended at the same place again is one array copy, not a loop over every index.
func append(o: DmHudMesh) -> void:
	var base := pts.size()
	pts.append_array(o.pts)
	cols.append_array(o.cols)
	idx.append_array(o._indices_from(base))


func _indices_from(base: int) -> PackedInt32Array:
	if base == 0:
		return idx
	var moved: Variant = _moved.get(base)
	if moved != null:
		return moved
	var out := idx.duplicate()
	for k in out.size():
		out[k] += base
	if _moved.size() < MOVED_KEEP:
		_moved[base] = out   # (`clear` drops them)
	return out


## Draws the bag as one command on `item` (call inside its `_draw`).
func submit(item: CanvasItem) -> void:
	if idx.is_empty():
		return
	RenderingServer.canvas_item_add_triangle_array(item.get_canvas_item(), idx, pts, cols)
	DmHudKit.rec_unique(item, "poly")


## An ArrayMesh of the bag (art that never changes: build once, `draw_mesh(mesh, null)` forever).
func to_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if idx.is_empty():
		return mesh
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh
