class_name DmNav
extends RefCounted
## Port of src/gameplay/nav.ts: walkable space = area rectangles + the corridors of open doors; obstacles push bodies out; A* over a
## 0.5 m grid for the last leg. Rects are Dictionaries {x0, z0, x1, z1} (the exported JSON shape).

const CELL := 4.0

static var _areas: Dictionary = {}
static var _area_order: Array = []
static var _doors: Array = []
static var _ready_: bool = false

var _obstacles: Array = []
## cell key -> Array of DmNavObstacle
var _grid: Dictionary = {}
var _unlocked: Dictionary = {}
var _instances: Dictionary = {}
var _floor: Variant = null
var _floor_obs: Array = []
var _floor_sight: Array = []
var _sight_blockers: Array = []
var _walk_cache: Variant = null
var _free_cache: Dictionary = {}


static func _load() -> void:
	if _ready_:
		return
	_areas = DmContent.areas()
	_area_order = DmContent.area_order()
	_doors = DmContent.doors()
	_ready_ = true


static func _gk(cx: int, cz: int) -> int:
	return (cx + 32768) * 65536 + (cz + 32768)


static func _in_rect(r: Dictionary, x: float, z: float, pad: float = 0.0) -> bool:
	return x >= float(r["x0"]) + pad and x <= float(r["x1"]) - pad and z >= float(r["z0"]) + pad and z <= float(r["z1"]) - pad


static func _clamp_to_rect(r: Dictionary, x: float, z: float, pad: float) -> Array:
	return [minf(maxf(x, float(r["x0"]) + pad), float(r["x1"]) - pad), minf(maxf(z, float(r["z0"]) + pad), float(r["z1"]) - pad)]


## Points are 2-element Arrays [x, z] (Godot's Vector2 is float32, which would not reproduce the TS doubles).
static func rect_center(r: Dictionary) -> Array:
	return [(float(r["x0"]) + float(r["x1"])) / 2.0, (float(r["z0"]) + float(r["z1"])) / 2.0]


static func is_always_open(id: String) -> bool:
	_load()
	var a: Dictionary = _areas[id]
	return not DmCombatData.truthy(a.get("unlock")) and not DmCombatData.truthy(a.get("instance"))


func _init() -> void:
	_load()
	for id in _area_order:
		if is_always_open(id):
			_unlocked[id] = true


## Open exactly these areas (plus the always-open ones). Instances are opened by their run, never here.
func set_unlocked(areas: Array) -> void:
	_drop_free()
	_unlocked = {}
	for id in areas:
		if not DmCombatData.truthy(_areas[id].get("instance")):
			_unlocked[id] = true
	for id in _area_order:
		if is_always_open(id):
			_unlocked[id] = true


func is_unlocked(area: String) -> bool:
	return _unlocked.has(area) or _instances.has(area)


func is_door_open(door: Dictionary) -> bool:
	return is_unlocked(door["a"]) and is_unlocked(door["b"])


func depths_floor() -> Variant:
	return _floor


func open_instance(id: String) -> void:
	_instances[id] = true
	_drop_free()


func close_instance(id: String) -> void:
	_instances.erase(id)
	_drop_free()


func load_depths_floor(floor_: Dictionary) -> void:
	clear_depths_floor()
	_floor = floor_
	_floor_obs = DmDepthsFloor.floor_obstacles(floor_)
	for o in _floor_obs:
		add_obstacle(o)
	_floor_sight = DmDepthsFloor.floor_sight_boxes(floor_)


func clear_depths_floor() -> void:
	for o in _floor_obs:
		_remove_obstacle(o)
	_floor_obs = []
	_floor_sight = []
	_floor = null


## Next place to steer for on a Depths floor: {x, z} or null.
func depths_hop(fx: float, fz: float, tx: float, tz: float) -> Variant:
	return DmDepthsFloor.floor_hop(_floor, fx, fz, tx, tz) if _floor != null else null


func add_sight_blocker(b: DmNavObstacle) -> void:
	_sight_blockers.append(b)


func _remove_obstacle(o: DmNavObstacle) -> void:
	_drop_free()
	var i := _obstacles.find(o)
	if i >= 0:
		_obstacles.remove_at(i)
	var b := _bounds(o)
	for cx in range(int(floorf(b[0] / CELL)), int(floorf(b[2] / CELL)) + 1):
		for cz in range(int(floorf(b[1] / CELL)), int(floorf(b[3] / CELL)) + 1):
			var k := _gk(cx, cz)
			if not _grid.has(k):
				continue
			var list: Array = _grid[k]
			var at := list.find(o)
			if at >= 0:
				list.remove_at(at)
			if list.is_empty():
				_grid.erase(k)


static func _bounds(o: DmNavObstacle) -> Array:
	if o.is_circle:
		return [o.x - o.r, o.z - o.r, o.x + o.r, o.z + o.r]
	return [o.x0, o.z0, o.x1, o.z1]


## Does the straight line a->b pass through a tall wall? (Liang-Barsky against each box.)
func sight_blocked(ax: float, az: float, bx: float, bz: float) -> bool:
	var dx := bx - ax
	var dz := bz - az
	var walls: Array = _sight_blockers + _floor_sight if not _floor_sight.is_empty() else _sight_blockers
	for w: DmNavObstacle in walls:
		var t0 := 0.0
		var t1 := 1.0
		var hit := true
		var ps := [-dx, dx, -dz, dz]
		var qs := [ax - w.x0, w.x1 - ax, az - w.z0, w.z1 - az]
		for i in 4:
			var p: float = ps[i]
			var q: float = qs[i]
			if p == 0.0:
				if q < 0.0:
					hit = false
					break
			else:
				var r := q / p
				if p < 0.0:
					if r > t1:
						hit = false
						break
					if r > t0:
						t0 = r
				else:
					if r < t0:
						hit = false
						break
					if r < t1:
						t1 = r
		if hit:
			return true
	return false


func add_obstacle(o: DmNavObstacle) -> void:
	_drop_free()
	_obstacles.append(o)
	var b := _bounds(o)
	for cx in range(int(floorf(b[0] / CELL)), int(floorf(b[2] / CELL)) + 1):
		for cz in range(int(floorf(b[1] / CELL)), int(floorf(b[3] / CELL)) + 1):
			var k := _gk(cx, cz)
			if not _grid.has(k):
				_grid[k] = []
			_grid[k].append(o)


func obstacle_count() -> int:
	return _obstacles.size()


func _drop_free() -> void:
	_walk_cache = null
	if not _free_cache.is_empty():
		_free_cache.clear()


func _walkables() -> Array:
	if _walk_cache != null:
		return _walk_cache
	var list: Array = []
	for id in _area_order:
		if is_unlocked(id):
			list.append(_areas[id]["rect"])
	for d in _doors:
		if is_door_open(d):
			list.append(d["rect"])
	_walk_cache = list
	return list


func area_at(x: float, z: float) -> String:
	for id in _area_order:
		if _in_rect(_areas[id]["rect"], x, z):
			return id
	return ""


## Push a body of radius r out of obstacles.
func push_out(x: float, z: float, r: float) -> Array:
	for pass_ in 2:
		var k := _gk(int(floorf(x / CELL)), int(floorf(z / CELL)))
		if not _grid.has(k):
			break
		var list: Array = _grid[k]
		var moved := false
		for o: DmNavObstacle in list:
			if o.is_circle:
				var dx := x - o.x
				var dz := z - o.z
				var d := DmSimMath.hypot(dx, dz)
				var mn := o.r + r
				if d < mn:
					var nx := dx / d if d > 1e-4 else 1.0
					var nz := dz / d if d > 1e-4 else 0.0
					x = o.x + nx * mn
					z = o.z + nz * mn
					moved = true
			else:
				var cx := minf(maxf(x, o.x0), o.x1)
				var cz := minf(maxf(z, o.z0), o.z1)
				var dx := x - cx
				var dz := z - cz
				var d := DmSimMath.hypot(dx, dz)
				if d < r:
					if d > 1e-4:
						x = cx + (dx / d) * r
						z = cz + (dz / d) * r
					else:
						var e0 := x - o.x0
						var e1 := o.x1 - x
						var e2 := z - o.z0
						var e3 := o.z1 - z
						var m := minf(minf(e0, e1), minf(e2, e3))
						if e0 == m:
							x = o.x0 - r
						elif e1 == m:
							x = o.x1 + r
						elif e2 == m:
							z = o.z0 - r
						else:
							z = o.z1 + r
					moved = true
		if not moved:
			break
	return [x, z]


## Clamp into walkable space (areas + open doors), then out of obstacles.
func resolve(x: float, z: float, r: float) -> Array:
	var p := push_out(x, z, r)
	x = p[0]
	z = p[1]
	var rects := _walkables()
	for rect: Dictionary in rects:
		if _in_rect(rect, x, z, r):
			return [x, z]
	var best: Array = [x, z]
	var best_d := INF
	for rect: Dictionary in rects:
		var c := _clamp_to_rect(rect, x, z, r)
		var d: float = (c[0] - x) * (c[0] - x) + (c[1] - z) * (c[1] - z)
		if d < best_d:
			best_d = d
			best = [c[0], c[1]]
	return best


## Enemies stay inside their own area.
func resolve_in_area(area: String, x: float, z: float, r: float) -> Array:
	var p := push_out(x, z, r)
	return _clamp_to_rect(_areas[area]["rect"], p[0], p[1], r)


## Waypoints (Array of [x, z]) from one point to another, via door centres when crossing areas.
func route(fx: float, fz: float, tx: float, tz: float) -> Array:
	var from := area_at(fx, fz)
	if from == "":
		from = nearest_area(fx, fz)
	var to := area_at(tx, tz)
	if to == "":
		to = nearest_area(tx, tz)
	if from == "depths" and to == "depths" and _floor != null:
		return DmDepthsFloor.floor_path(_floor, fx, fz, tx, tz)
	if from == "" or to == "" or from == to:
		return [[tx, tz]]
	var prev: Dictionary = {}
	var queue: Array = [from]
	var seen: Dictionary = {from: true}
	var qi := 0
	while qi < queue.size():
		var cur: String = queue[qi]
		qi += 1
		if cur == to:
			break
		for d: Dictionary in _doors:
			if not is_door_open(d):
				continue
			var nxt := ""
			if d["a"] == cur:
				nxt = d["b"]
			elif d["b"] == cur:
				nxt = d["a"]
			if nxt == "" or seen.has(nxt):
				continue
			seen[nxt] = true
			prev[nxt] = {"area": cur, "door": d}
			queue.append(nxt)
	if not prev.has(to):
		return [_clamp_to_rect(_areas[from]["rect"], tx, tz, 0.6)]
	var doors: Array = []
	var a: String = to
	while a != from:
		var p: Dictionary = prev[a]
		doors.push_front(p["door"])
		a = p["area"]
	var pts: Array = []
	for d: Dictionary in doors:
		var rc: Dictionary = d["rect"]
		var c := rect_center(rc)
		if d["axis"] == "z":
			var from_south: bool = fz > c[1]
			pts.append([c[0], float(rc["z1"]) if from_south else float(rc["z0"])])
			pts.append([c[0], float(rc["z0"]) if from_south else float(rc["z1"])])
		else:
			var from_west: bool = fx < c[0]
			pts.append([float(rc["x0"]) if from_west else float(rc["x1"]), c[1]])
			pts.append([float(rc["x1"]) if from_west else float(rc["x0"]), c[1]])
		fx = pts[pts.size() - 1][0]
		fz = pts[pts.size() - 1][1]
	pts.append([tx, tz])
	return pts


## True when a body of radius r at (x, z) overlaps an obstacle or leaves walkable space.
func blocked(x: float, z: float, r: float) -> bool:
	var rects := _walkables()
	var inside := false
	var i := 0
	while i < rects.size() and not inside:
		inside = _in_rect(rects[i], x, z, r)
		i += 1
	if not inside:
		return true
	for cx in range(int(floorf((x - r) / CELL)), int(floorf((x + r) / CELL)) + 1):
		for cz in range(int(floorf((z - r) / CELL)), int(floorf((z + r) / CELL)) + 1):
			var k := _gk(cx, cz)
			if not _grid.has(k):
				continue
			for o: DmNavObstacle in _grid[k]:
				if o.is_circle:
					if DmSimMath.hypot(x - o.x, z - o.z) < o.r + r:
						return true
				else:
					var px := minf(maxf(x, o.x0), o.x1)
					var pz := minf(maxf(z, o.z0), o.z1)
					if DmSimMath.hypot(x - px, z - pz) < r:
						return true
	return false


func clear_line(ax: float, az: float, bx: float, bz: float, r: float) -> bool:
	var n := maxi(1, int(ceilf(DmSimMath.hypot(bx - ax, bz - az) / 0.25)))
	for i in range(1, n + 1):
		if blocked(ax + ((bx - ax) * i) / n, az + ((bz - az) * i) / n, r):
			return false
	return true


## Obstacle-aware waypoints (Array of [x, z]): door route, then A* inside the destination room for the last leg.
func find_path(fx: float, fz: float, tx: float, tz: float, r: float = 0.45) -> Array:
	var legs := route(fx, fz, tx, tz)
	var out: Array = []
	var at: Array = [fx, fz]
	for p: Array in legs:
		var area := area_at((at[0] + p[0]) / 2.0, (at[1] + p[1]) / 2.0)
		if area == "":
			area = area_at(p[0], p[1])
		var inner: Variant = null
		if area != "" and not clear_line(at[0], at[1], p[0], p[1], r):
			inner = _grid_path(_areas[area]["rect"], at, p, r)
		if inner != null:
			out.append_array(inner)
		else:
			out.append(p)
		at = p
	return out


func _grid_path(rect: Dictionary, from: Array, to: Array, r: float) -> Variant:
	const S := 0.5
	var rx0 := float(rect["x0"])
	var rz0 := float(rect["z0"])
	var w := int(ceilf((float(rect["x1"]) - rx0) / S))
	var h := int(ceilf((float(rect["z1"]) - rz0) / S))
	var ck := "%s,%s,%s,%s,%s" % [rect["x0"], rect["z0"], rect["x1"], rect["z1"], r]
	if not _free_cache.has(ck):
		var arr := PackedByteArray()
		arr.resize(w * h)
		arr.fill(2)  # 2 unknown, 0 blocked, 1 free
		_free_cache[ck] = arr
	var free: PackedByteArray = _free_cache[ck]
	var is_free := func(i: int) -> bool:
		if free[i] == 2:
			free[i] = 0 if blocked(rx0 + (i % w) * S + S / 2.0, rz0 + (i / w) * S + S / 2.0, r) else 1
		return free[i] == 1
	var cell_of := func(x: float, z: float) -> int:
		var i := mini(w - 1, maxi(0, int(floorf((x - rx0) / S))))
		var j := mini(h - 1, maxi(0, int(floorf((z - rz0) / S))))
		return j * w + i
	var snap := func(c: int) -> int:
		if is_free.call(c):
			return c
		for ring in range(1, 6):
			var best := -1
			var best_d := INF
			var ci := c % w
			var cj := c / w
			for dj in range(-ring, ring + 1):
				for di in range(-ring, ring + 1):
					var i := ci + di
					var j := cj + dj
					if i < 0 or j < 0 or i >= w or j >= h:
						continue
					var k := j * w + i
					var d := float(di * di + dj * dj)
					if d < best_d and is_free.call(k):
						best_d = d
						best = k
			if best >= 0:
				return best
		return -1
	var s: int = snap.call(cell_of.call(from[0], from[1]))
	var g: int = snap.call(cell_of.call(to[0], to[1]))
	if s < 0 or g < 0:
		return null
	var gx := g % w
	var gy := g / w
	var cost := PackedFloat32Array()
	cost.resize(w * h)
	cost.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(w * h)
	prev.fill(-1)
	var closed := PackedByteArray()
	closed.resize(w * h)
	var heap_f: Array = []
	var heap_k: Array = []
	cost[s] = 0.0
	_heap_push(heap_f, heap_k, DmSimMath.hypot(float((s % w) - gx), float((s / w) - gy)), s)
	var found := false
	var guard := 0
	while not heap_f.is_empty() and guard < w * h * 4:
		guard += 1
		var k := _heap_pop(heap_f, heap_k)
		if closed[k] != 0:
			continue
		closed[k] = 1
		if k == g:
			found = true
			break
		var ki := k % w
		var kj := k / w
		for dj in range(-1, 2):
			for di in range(-1, 2):
				if di == 0 and dj == 0:
					continue
				var i := ki + di
				var j := kj + dj
				if i < 0 or j < 0 or i >= w or j >= h:
					continue
				var n := j * w + i
				if not is_free.call(n):
					continue
				if di != 0 and dj != 0 and (not is_free.call(kj * w + i) or not is_free.call(j * w + ki)):
					continue
				var c: float = cost[k] + (sqrt(2.0) if (di != 0 and dj != 0) else 1.0)
				if c < cost[n]:
					cost[n] = c
					prev[n] = k
					_heap_push(heap_f, heap_k, c + DmSimMath.hypot(float((n % w) - gx), float((n / w) - gy)), n)
	if not found:
		return null
	var cells: Array = []
	var kk := g
	while kk >= 0:
		cells.push_front([rx0 + (kk % w) * S + S / 2.0, rz0 + (kk / w) * S + S / 2.0])
		kk = prev[kk]
	cells.append([to[0], to[1]])
	var out: Array = []
	var at: Array = [from[0], from[1]]
	var i2 := 0
	while i2 < cells.size():
		var far_ := i2
		while far_ + 1 < cells.size() and clear_line(at[0], at[1], cells[far_ + 1][0], cells[far_ + 1][1], r * 0.9):
			far_ += 1
		out.append(cells[far_])
		at = cells[far_]
		i2 = far_ + 1
	return out


static func _heap_push(hf: Array, hk: Array, f: float, k: int) -> void:
	hf.append(f)
	hk.append(k)
	var i := hf.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if hf[p] <= hf[i]:
			break
		var tf: float = hf[p]
		hf[p] = hf[i]
		hf[i] = tf
		var tk: int = hk[p]
		hk[p] = hk[i]
		hk[i] = tk
		i = p


static func _heap_pop(hf: Array, hk: Array) -> int:
	var top: int = hk[0]
	var last_f: float = hf.pop_back()
	var last_k: int = hk.pop_back()
	if not hf.is_empty():
		hf[0] = last_f
		hk[0] = last_k
		var i := 0
		while true:
			var l := i * 2 + 1
			var rr := l + 1
			var m := i
			if l < hf.size() and hf[l] < hf[m]:
				m = l
			if rr < hf.size() and hf[rr] < hf[m]:
				m = rr
			if m == i:
				break
			var tf: float = hf[m]
			hf[m] = hf[i]
			hf[i] = tf
			var tk: int = hk[m]
			hk[m] = hk[i]
			hk[i] = tk
			i = m
	return top


func nearest_area(x: float, z: float) -> String:
	var best := ""
	var best_d := INF
	for id in _area_order:
		var c := _clamp_to_rect(_areas[id]["rect"], x, z, 0.0)
		var d: float = (c[0] - x) * (c[0] - x) + (c[1] - z) * (c[1] - z)
		if d < best_d:
			best_d = d
			best = id
	return best
