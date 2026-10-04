class_name DmDepthsFloor
extends RefCounted
## Port of src/gameplay/depthsFloor.ts: the Catacomb Depths floor generator (pure, deterministic: same (seed, depth) -> same floor)
## and its navigation helpers. A floor is a Dictionary with the TS field names:
##   {seed, depth, rect, rooms:[{id,col,row,rect,cx,cz,active,kind,adj:[{to,door}],dist}], doors:[{a,b,x,z,wall,dir:{x,z}}], walls:[WallSegment dict],
##    props:[Placement dict], stairUp:{x,z}, start:{x,z}, stairDown:{x,z}, chest:{x,z}|null, startRoom, stairRoom, chestRoom|null,
##    breaches:[{x,z,room}], next:[[int]]}
## Rects are {x0,z0,x1,z1}; WallSegment {x0,z0,x1,z1,height,thickness,texture,area}; Placement {prop,x,z,rot,scale,area,...}.

const FLOOR_COLS := 3
const FLOOR_ROWS := 3
const FLOOR_WALL_H := 3.4
const WALL_T := 1.0
const DOOR_W := 4.6
const DOOR_KEEPOUT := 3.4
const LANE_HALF := 1.2
const BODY := 0.45
const STAIR_R := 0.8
const CHEST_R := 0.7
const MOUTH_DEPTH := 1.6
const MOUTH_HALF := DOOR_W / 2.0 + 0.5
const ROOM_KINDS: Array[String] = ["pillars", "crypt", "cages", "bones", "ossuary", "plain"]


static func _rect() -> Dictionary:
	return DmContent.get_export("areas", "DEPTHS_RECT")


static func _cell_w(r: Dictionary) -> float:
	return (float(r["x1"]) - float(r["x0"])) / FLOOR_COLS


static func _cell_h(r: Dictionary) -> float:
	return (float(r["z1"]) - float(r["z0"])) / FLOOR_ROWS


static func room_at(f: Dictionary, x: float, z: float) -> int:
	var r: Dictionary = f["rect"]
	if x < float(r["x0"]) or x > float(r["x1"]) or z < float(r["z0"]) or z > float(r["z1"]):
		return -1
	var col := mini(FLOOR_COLS - 1, int(floorf((x - float(r["x0"])) / _cell_w(r))))
	var row := mini(FLOOR_ROWS - 1, int(floorf((z - float(r["z0"])) / _cell_h(r))))
	var room: Dictionary = f["rooms"][row * FLOOR_COLS + col]
	return int(room["id"]) if room["active"] else -1


static func _beyond(d: Dictionary, toward_b: bool) -> Array:
	var s := 1.0 if toward_b else -1.0
	return [float(d["x"]) + float(d["dir"]["x"]) * s * 2.0, float(d["z"]) + float(d["dir"]["z"]) * s * 2.0]


## Next place to head for when walking (fx,fz)->(tx,tz): null or {x, z}.
static func floor_hop(f: Dictionary, fx: float, fz: float, tx: float, tz: float) -> Variant:
	var a := room_at(f, fx, fz)
	var b := room_at(f, tx, tz)
	if a < 0 or b < 0:
		return null
	var through := -1 if a == b else int(f["next"][a][b])
	if a != b and through < 0:
		return null
	var doors: Array = []
	if a == b:
		for x in f["rooms"][a]["adj"]:
			doors.append(int(x["door"]))
	else:
		doors = [through]
	for di in doors:
		var d: Dictionary = f["doors"][di]
		var dx: float = d["dir"]["x"]
		var dz: float = d["dir"]["z"]
		var along := (fx - float(d["x"])) * dx + (fz - float(d["z"])) * dz
		var across := (fx - float(d["x"])) * -dz + (fz - float(d["z"])) * dx
		if absf(along) >= MOUTH_DEPTH or absf(across) >= MOUTH_HALF:
			continue
		var room: Dictionary = f["rooms"][a]
		var side: float
		if a == b:
			side = DmSimMath.sign_js((float(room["cx"]) - float(d["x"])) * dx + (float(room["cz"]) - float(d["z"])) * dz)
			if side == 0.0:
				side = 1.0
		else:
			side = 1.0 if int(d["a"]) == a else -1.0
		var t := maxf(-(DOOR_W / 2.0 - 0.6), minf(DOOR_W / 2.0 - 0.6, across))
		return {"x": float(d["x"]) + -dz * t + dx * side * 2.1, "z": float(d["z"]) + dx * t + dz * side * 2.1}
	if a == b:
		return null
	return {"x": f["doors"][through]["x"], "z": f["doors"][through]["z"]}


static func floor_hops(f: Dictionary, a: int, b: int) -> int:
	if a < 0 or b < 0:
		return -1
	var n := 0
	var at := a
	while at != b:
		var di := int(f["next"][at][b])
		if di < 0 or n > f["rooms"].size():
			return -1
		var d: Dictionary = f["doors"][di]
		at = int(d["b"]) if int(d["a"]) == at else int(d["a"])
		n += 1
	return n


## Waypoints ([x, z] Arrays) across the floor.
static func floor_path(f: Dictionary, fx: float, fz: float, tx: float, tz: float) -> Array:
	var a := room_at(f, fx, fz)
	var b := room_at(f, tx, tz)
	var out: Array = []
	if a < 0 or b < 0:
		return [[tx, tz]]
	var guard := 0
	while a != b and guard < f["rooms"].size():
		var di := int(f["next"][a][b])
		if di < 0:
			break
		var d: Dictionary = f["doors"][di]
		var from_a := int(d["a"]) == a
		out.append([float(d["x"]), float(d["z"])])
		out.append(_beyond(d, from_a))
		a = int(d["b"]) if from_a else int(d["a"])
		guard += 1
	out.append([tx, tz])
	return out


static func wall_obstacle(w: Dictionary) -> DmNavObstacle:
	var horizontal := absf(float(w["z1"]) - float(w["z0"])) < 1e-3
	var ln: float = (float(w["x1"]) - float(w["x0"])) if horizontal else (float(w["z1"]) - float(w["z0"]))
	var hw: float = ln / 2.0 if horizontal else float(w["thickness"]) / 2.0
	var hd: float = float(w["thickness"]) / 2.0 if horizontal else ln / 2.0
	var mx := (float(w["x0"]) + float(w["x1"])) / 2.0
	var mz := (float(w["z0"]) + float(w["z1"])) / 2.0
	return DmNavObstacle.box(mx - hw, mz - hd, mx + hw, mz + hd)


static func placement_obstacle(p: Dictionary) -> DmNavObstacle:
	var c: Variant = DmContent.get_export("layout", "PROPS")[p["prop"]].get("collider")
	if c == null:
		return null
	var sc := float(p["scale"])
	if c["kind"] == "circle":
		return DmNavObstacle.circle(float(p["x"]), float(p["z"]), float(c["r"]) * sc)
	if c["kind"] == "box":
		var rot := float(p["rot"])
		var cs := absf(DmFdlibm.cos_(rot))
		var sn := absf(DmFdlibm.sin_(rot))
		var hw := (float(c["hw"]) * cs + float(c["hd"]) * sn) * sc
		var hd := (float(c["hw"]) * sn + float(c["hd"]) * cs) * sc
		return DmNavObstacle.box(float(p["x"]) - hw, float(p["z"]) - hd, float(p["x"]) + hw, float(p["z"]) + hd)
	return null


static func floor_obstacles(f: Dictionary) -> Array:
	var out: Array = []
	for w in f["walls"]:
		out.append(wall_obstacle(w))
	for p in f["props"]:
		var o := placement_obstacle(p)
		if o != null:
			out.append(o)
	out.append(DmNavObstacle.circle(float(f["stairUp"]["x"]), float(f["stairUp"]["z"]), STAIR_R))
	out.append(DmNavObstacle.circle(float(f["stairDown"]["x"]), float(f["stairDown"]["z"]), STAIR_R))
	if f["chest"] != null:
		out.append(DmNavObstacle.circle(float(f["chest"]["x"]), float(f["chest"]["z"]), CHEST_R))
	return out


static func floor_sight_boxes(f: Dictionary) -> Array:
	var out: Array = []
	for w in f["walls"]:
		if float(w["height"]) >= 2.5:
			out.append(wall_obstacle(w))
	return out


## Names everything on the floor that cannot be walked to from the way in; empty = a sound floor.
static func floor_problems(f: Dictionary) -> Array:
	var problems: Array = []
	var obstacles := floor_obstacles(f)
	var r: Dictionary = f["rect"]
	var rx0 := float(r["x0"])
	var rz0 := float(r["z0"])
	var rx1 := float(r["x1"])
	var rz1 := float(r["z1"])
	const S := 0.5
	var w := int(ceilf((rx1 - rx0) / S))
	var h := int(ceilf((rz1 - rz0) / S))
	var free := PackedByteArray()
	free.resize(w * h)
	free.fill(1)
	for j in h:
		for i in w:
			var x := rx0 + i * S + S / 2.0
			var z := rz0 + j * S + S / 2.0
			if x < rx0 + BODY or x > rx1 - BODY or z < rz0 + BODY or z > rz1 - BODY:
				free[j * w + i] = 0
	for o: DmNavObstacle in obstacles:
		var b := DmNav._bounds(o)
		var i0 := maxi(0, int(floorf((b[0] - BODY - rx0) / S)))
		var i1 := mini(w - 1, int(floorf((b[2] + BODY - rx0) / S)))
		var j0 := maxi(0, int(floorf((b[1] - BODY - rz0) / S)))
		var j1 := mini(h - 1, int(floorf((b[3] + BODY - rz0) / S)))
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var x := rx0 + i * S + S / 2.0
				var z := rz0 + j * S + S / 2.0
				var blk: bool
				if o.is_circle:
					blk = DmSimMath.hypot(x - o.x, z - o.z) < o.r + BODY
				else:
					blk = DmSimMath.hypot(x - minf(maxf(x, o.x0), o.x1), z - minf(maxf(z, o.z0), o.z1)) < BODY
				if blk:
					free[j * w + i] = 0
	var cell := func(x: float, y: float) -> int:
		return mini(h - 1, maxi(0, int(floorf((y - rz0) / S)))) * w + mini(w - 1, maxi(0, int(floorf((x - rx0) / S))))
	var from: int = cell.call(float(f["start"]["x"]), float(f["start"]["z"]))
	if free[from] == 0:
		return ["the way in is blocked"]
	var seen := PackedByteArray()
	seen.resize(w * h)
	var queue: Array = [from]
	seen[from] = 1
	var q := 0
	while q < queue.size():
		var k: int = queue[q]
		q += 1
		var ki := k % w
		var kj := k / w
		for dd in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
			var i: int = ki + dd[0]
			var j: int = kj + dd[1]
			if i < 0 or j < 0 or i >= w or j >= h:
				continue
			var n := j * w + i
			if seen[n] != 0 or free[n] == 0:
				continue
			seen[n] = 1
			queue.append(n)
	var reach := func(label: String, x: float, z: float) -> void:
		var k: int = cell.call(x, z)
		if free[k] == 0 or seen[k] == 0:
			problems.append("%s at %.1f,%.1f cannot be walked to" % [label, x, z])
	for room: Dictionary in f["rooms"]:
		if not room["active"]:
			continue
		var ok := false
		var rr: Dictionary = room["rect"]
		var j := int(ceilf((float(rr["z0"]) - rz0) / S))
		while j < int(floorf((float(rr["z1"]) - rz0) / S)) and not ok:
			for i in range(int(ceilf((float(rr["x0"]) - rx0) / S)), int(floorf((float(rr["x1"]) - rx0) / S))):
				if seen[j * w + i] != 0:
					ok = true
					break
			j += 1
		if not ok:
			problems.append("room %d cannot be walked to" % int(room["id"]))
	var di := 0
	for d: Dictionary in f["doors"]:
		var dx: float = d["dir"]["x"]
		var dz: float = d["dir"]["z"]
		reach.call("door %d" % di, float(d["x"]), float(d["z"]))
		reach.call("door %d (a side)" % di, float(d["x"]) - dx * 2.0, float(d["z"]) - dz * 2.0)
		reach.call("door %d (b side)" % di, float(d["x"]) + dx * 2.0, float(d["z"]) + dz * 2.0)
		di += 1
	reach.call("stair up", float(f["stairUp"]["x"]), float(f["stairUp"]["z"]) + 1.4)
	reach.call("stair down", float(f["stairDown"]["x"]), float(f["stairDown"]["z"]) + 1.4)
	if f["chest"] != null:
		reach.call("chest", float(f["chest"]["x"]), float(f["chest"]["z"]) + 1.4)
	var bi := 0
	for b: Dictionary in f["breaches"]:
		reach.call("spawn point %d" % bi, float(b["x"]), float(b["z"]))
		bi += 1
	return problems


# --- Generation -------------------------------------------------------------------------------------------------------

static func floor_seed(run_seed: int, depth: int) -> int:
	var a: int = ((int(run_seed) ^ 0x9e3779b9) & 0xFFFFFFFF) * 0x85ebca6b
	a = a & 0xFFFFFFFF
	var b: int = ((depth + 1) * 0xc2b2ae35) & 0xFFFFFFFF
	return (a ^ b) & 0xFFFFFFFF


static func generate_floor(seed_: int, depth: int, chest_every: int = 5) -> Dictionary:
	var base := _skeleton(seed_, depth, chest_every)
	for attempt in 10:
		var f := _dress(base, seed_, attempt)
		if floor_problems(f).is_empty():
			return f
	return _dress(base, seed_, -1)


static func _skeleton(seed_: int, depth: int, chest_every: int) -> Dictionary:
	var rng := DmRng.new((seed_ ^ 0x51ed) & 0xFFFFFFFF)
	var rect: Dictionary = _rect()
	var cw := _cell_w(rect)
	var ch := _cell_h(rect)
	var rooms: Array = []
	for row in FLOOR_ROWS:
		for col in FLOOR_COLS:
			var x0 := float(rect["x0"]) + col * cw
			var z0 := float(rect["z0"]) + row * ch
			var inner := {
				"x0": x0 + (WALL_T / 2.0 if col > 0 else 0.0), "z0": z0 + (WALL_T / 2.0 if row > 0 else 0.0),
				"x1": x0 + cw - (WALL_T / 2.0 if col < FLOOR_COLS - 1 else 0.0), "z1": z0 + ch - (WALL_T / 2.0 if row < FLOOR_ROWS - 1 else 0.0),
			}
			rooms.append({"id": row * FLOOR_COLS + col, "col": col, "row": row, "rect": inner, "cx": (inner["x0"] + inner["x1"]) / 2.0, "cz": (inner["z0"] + inner["z1"]) / 2.0, "active": true, "kind": "plain", "adj": [], "dist": 0})
	var at := func(col: int, row: int) -> Variant:
		return null if (col < 0 or row < 0 or col >= FLOOR_COLS or row >= FLOOR_ROWS) else rooms[row * FLOOR_COLS + col]
	var neighbours := func(r: Dictionary) -> Array:
		var out: Array = []
		for n in [at.call(r["col"] + 1, r["row"]), at.call(r["col"] - 1, r["row"]), at.call(r["col"], r["row"] + 1), at.call(r["col"], r["row"] - 1)]:
			if n != null and n["active"]:
				out.append(n)
		return out
	var reachable_count := func() -> int:
		var start: Dictionary = {}
		for r in rooms:
			if r["active"]:
				start = r
				break
		var seen: Dictionary = {int(start["id"]): true}
		var stack: Array = [start]
		while not stack.is_empty():
			var cur: Dictionary = stack.pop_back()
			for n in neighbours.call(cur):
				if not seen.has(int(n["id"])):
					seen[int(n["id"])] = true
					stack.append(n)
		return seen.size()
	var removals := int(floorf(rng.next() * 3.0))
	var candidates: Array = []
	for r in rooms:
		if int(r["id"]) != 4:
			candidates.append(r)
	var i := candidates.size() - 1
	while i > 0:
		var j := int(floorf(rng.next() * (i + 1)))
		var tmp = candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = tmp
		i -= 1
	var removed := 0
	for c: Dictionary in candidates:
		if removed >= removals:
			break
		c["active"] = false
		var active_n := 0
		for r in rooms:
			if r["active"]:
				active_n += 1
		if reachable_count.call() == active_n:
			removed += 1
		else:
			c["active"] = true
	var pairs: Array = []
	for r: Dictionary in rooms:
		if not r["active"]:
			continue
		var e: Variant = at.call(r["col"] + 1, r["row"])
		var s: Variant = at.call(r["col"], r["row"] + 1)
		if e != null and e["active"]:
			pairs.append([r, e])
		if s != null and s["active"]:
			pairs.append([r, s])
	i = pairs.size() - 1
	while i > 0:
		var j := int(floorf(rng.next() * (i + 1)))
		var tmp = pairs[i]
		pairs[i] = pairs[j]
		pairs[j] = tmp
		i -= 1
	var parent: Array = []
	for r in rooms:
		parent.append(int(r["id"]))
	var find := func(x: int) -> int:
		var root := x
		while parent[root] != root:
			root = parent[root]
		# path compression (same result as the recursive TS form)
		var cur := x
		while parent[cur] != root:
			var nx: int = parent[cur]
			parent[cur] = root
			cur = nx
		return root
	var chosen: Array = []
	var spare: Array = []
	for p: Array in pairs:
		var a: int = find.call(int(p[0]["id"]))
		var b: int = find.call(int(p[1]["id"]))
		if a != b:
			parent[a] = b
			chosen.append(p)
		else:
			spare.append(p)
	var extra := 1 + int(floorf(rng.next() * 3.0))
	for k in range(mini(extra, spare.size())):
		chosen.append(spare[k])
	var doors: Array = []
	var margin := DOOR_W / 2.0 + 1.4
	for p: Array in chosen:
		var a: Dictionary = p[0]
		var b: Dictionary = p[1]
		var door: Dictionary
		if int(b["col"]) != int(a["col"]):
			var x := float(rect["x0"]) + (int(a["col"]) + 1) * cw
			var z := float(rect["z0"]) + int(a["row"]) * ch + margin + rng.next() * (ch - 2.0 * margin)
			door = {"a": a["id"], "b": b["id"], "x": x, "z": z, "wall": "x", "dir": {"x": 1.0, "z": 0.0}}
		else:
			var z := float(rect["z0"]) + (int(a["row"]) + 1) * ch
			var x := float(rect["x0"]) + int(a["col"]) * cw + margin + rng.next() * (cw - 2.0 * margin)
			door = {"a": a["id"], "b": b["id"], "x": x, "z": z, "wall": "z", "dir": {"x": 0.0, "z": 1.0}}
		doors.append(door)
		a["adj"].append({"to": b["id"], "door": doors.size() - 1})
		b["adj"].append({"to": a["id"], "door": doors.size() - 1})
	var active: Array = []
	for r in rooms:
		if r["active"]:
			active.append(r)
	var max_row := 0
	for r in active:
		max_row = maxi(max_row, int(r["row"]))
	var southern: Array = []
	for r in active:
		if int(r["row"]) == max_row:
			southern.append(r)
	var start_room: Dictionary = southern[int(floorf(rng.next() * southern.size()))]
	var bfs := func(from: Dictionary) -> Dictionary:
		var dist: Dictionary = {int(from["id"]): 0}
		var queue: Array = [from]
		var q := 0
		while q < queue.size():
			var cur: Dictionary = queue[q]
			q += 1
			for adj in cur["adj"]:
				var to := int(adj["to"])
				if not dist.has(to):
					dist[to] = int(dist[int(cur["id"])]) + 1
					queue.append(rooms[to])
		return dist
	var dist: Dictionary = bfs.call(start_room)
	for r in active:
		r["dist"] = int(dist.get(int(r["id"]), 0))
	var far: Array = active.duplicate()
	far.sort_custom(func(a, b): return int(a["dist"]) > int(b["dist"]) or (int(a["dist"]) == int(b["dist"]) and int(a["id"]) < int(b["id"])))
	var top_dist := int(far[0]["dist"])
	var top_rooms: Array = []
	for r in far:
		if int(r["dist"]) == top_dist:
			top_rooms.append(r)
	var stair_room: Dictionary = top_rooms[int(floorf(rng.next() * top_rooms.size()))]
	var chest_room: Variant = null
	if chest_every > 0 and depth % chest_every == 0:
		var rest: Array = []
		for r in active:
			if int(r["id"]) != int(start_room["id"]) and int(r["id"]) != int(stair_room["id"]):
				rest.append(r)
		rest.sort_custom(func(a, b):
			var ka := 0 if a["adj"].size() == 1 else 1
			var kb := 0 if b["adj"].size() == 1 else 1
			if ka != kb:
				return ka < kb
			if int(a["dist"]) != int(b["dist"]):
				return int(a["dist"]) > int(b["dist"])
			return int(a["id"]) < int(b["id"]))
		chest_room = rest[0] if not rest.is_empty() else stair_room
		if chest_room == stair_room:
			chest_room = null
	for r: Dictionary in active:
		if r == start_room or r == stair_room or (chest_room != null and r == chest_room):
			r["kind"] = "plain" if r == start_room else "crypt"
		else:
			r["kind"] = ROOM_KINDS[int(floorf(rng.next() * ROOM_KINDS.size()))]
	var n := rooms.size()
	var next_: Array = []
	for a in n:
		var row: Array = []
		row.resize(n)
		row.fill(-1)
		next_.append(row)
	for target: Dictionary in active:
		var seen: Dictionary = {int(target["id"]): true}
		var queue: Array = [target]
		var q := 0
		while q < queue.size():
			var cur: Dictionary = queue[q]
			q += 1
			for adj in cur["adj"]:
				var to := int(adj["to"])
				if seen.has(to):
					continue
				seen[to] = true
				next_[to][int(target["id"])] = int(adj["door"])
				queue.append(rooms[to])
	var walls := _partition_walls(rect, rooms, doors)
	return {
		"seed": seed_, "depth": depth, "rect": rect, "rooms": rooms, "doors": doors, "walls": walls, "props": [],
		"stairUp": {"x": start_room["cx"], "z": float(start_room["rect"]["z1"]) - 2.6},
		"start": {"x": start_room["cx"], "z": float(start_room["rect"]["z1"]) - 5.2},
		"stairDown": {"x": stair_room["cx"], "z": float(stair_room["cz"]) - 1.5},
		"chest": ({"x": chest_room["cx"], "z": float(chest_room["cz"]) - 1.0} if chest_room != null else null),
		"startRoom": start_room["id"], "stairRoom": stair_room["id"], "chestRoom": (chest_room["id"] if chest_room != null else null),
		"breaches": [], "next": next_,
	}


static func _tall(x0: float, z0: float, x1: float, z1: float, thickness: float = WALL_T, height: float = FLOOR_WALL_H, texture: String = "stone_wall") -> Dictionary:
	return {"x0": x0, "z0": z0, "x1": x1, "z1": z1, "height": height, "thickness": thickness, "texture": texture, "area": "depths"}


static func _partition_walls(rect: Dictionary, rooms: Array, doors: Array) -> Array:
	var walls: Array = []
	var cw := _cell_w(rect)
	var ch := _cell_h(rect)
	const T := 0.8
	var rx0 := float(rect["x0"])
	var rz0 := float(rect["z0"])
	var rx1 := float(rect["x1"])
	var rz1 := float(rect["z1"])
	walls.append(_tall(rx0, rz0 - T / 2.0, rx1, rz0 - T / 2.0, T))
	walls.append(_tall(rx0, rz1 + T / 2.0, rx1, rz1 + T / 2.0, T, 1.1))
	walls.append(_tall(rx0 - T / 2.0, rz0, rx0 - T / 2.0, rz1, T))
	walls.append(_tall(rx1 + T / 2.0, rz0, rx1 + T / 2.0, rz1, T))
	var door_at := func(wall: String, fixed: float, from: float) -> Variant:
		for d: Dictionary in doors:
			if d["wall"] != wall:
				continue
			var fx: float = d["x"] if wall == "x" else d["z"]
			var other: float = d["z"] if wall == "x" else d["x"]
			var span := ch if wall == "x" else cw
			if absf(fx - fixed) < 1e-6 and other >= from - 1e-6 and other <= from + span + 1e-6:
				return d
		return null
	for c in range(1, FLOOR_COLS):
		var x := rx0 + c * cw
		for r in FLOOR_ROWS:
			var z0 := rz0 + r * ch
			var z1 := z0 + ch
			var d: Variant = door_at.call("x", x, z0)
			var lo := z0 - (WALL_T / 2.0 if r > 0 else 0.0)
			var hi := z1 + (WALL_T / 2.0 if r < FLOOR_ROWS - 1 else 0.0)
			if d == null:
				walls.append(_tall(x, lo, x, hi))
			else:
				walls.append(_tall(x, lo, x, float(d["z"]) - DOOR_W / 2.0))
				walls.append(_tall(x, float(d["z"]) + DOOR_W / 2.0, x, hi))
	for r in range(1, FLOOR_ROWS):
		var z := rz0 + r * ch
		for c in FLOOR_COLS:
			var x0 := rx0 + c * cw
			var x1 := x0 + cw
			var d: Variant = door_at.call("z", z, x0)
			var lo := x0 - (WALL_T / 2.0 if c > 0 else 0.0)
			var hi := x1 + (WALL_T / 2.0 if c < FLOOR_COLS - 1 else 0.0)
			if d == null:
				walls.append(_tall(lo, z, hi, z))
			else:
				walls.append(_tall(lo, z, float(d["x"]) - DOOR_W / 2.0, z))
				walls.append(_tall(float(d["x"]) + DOOR_W / 2.0, z, hi, z))
	for room: Dictionary in rooms:
		if room["active"]:
			continue
		var b: Dictionary = room["rect"]
		var midz := (float(b["z0"]) + float(b["z1"])) / 2.0
		walls.append(_tall(float(b["x0"]), midz, float(b["x1"]), midz, float(b["z1"]) - float(b["z0"])))
	return walls


static func _dress(base: Dictionary, seed_: int, attempt: int) -> Dictionary:
	var rng := DmRng.new((seed_ ^ (0x7a1e + attempt * 0x1f3d)) & 0xFFFFFFFF)
	var props: Array = []
	var walls: Array = base["walls"]
	var breaches: Array = []
	var density := 0.0 if attempt < 0 else maxf(0.25, 1.0 - attempt * 0.12)
	var P := func(prop: String, x: float, z: float, rot: float = NAN, scale: float = 1.0) -> void:
		var r := rot
		if is_nan(r):
			r = rng.next() * PI * 2.0
		props.append({"prop": prop, "x": x, "z": z, "rot": r, "scale": scale, "area": "depths"})
	var doors: Array = base["doors"]
	var near_door := func(x: float, z: float, pad: float = 0.0) -> bool:
		for d: Dictionary in doors:
			if DmSimMath.hypot(float(d["x"]) - x, float(d["z"]) - z) < DOOR_KEEPOUT + pad:
				return true
		return false
	var keep_clear: Array = [
		{"x": base["stairUp"]["x"], "z": base["stairUp"]["z"], "r": 3.2},
		{"x": base["start"]["x"], "z": base["start"]["z"], "r": 2.4},
		{"x": base["stairDown"]["x"], "z": base["stairDown"]["z"], "r": 3.2},
	]
	if base["chest"] != null:
		keep_clear.append({"x": base["chest"]["x"], "z": base["chest"]["z"], "r": 3.2})
	var lanes: Array = []
	for room: Dictionary in base["rooms"]:
		if not room["active"]:
			continue
		for adj in room["adj"]:
			var d: Dictionary = doors[int(adj["door"])]
			lanes.append({"ax": d["x"], "az": d["z"], "bx": room["cx"], "bz": room["cz"]})
	var on_lane := func(x: float, z: float, r: float) -> bool:
		for l: Dictionary in lanes:
			var dx: float = float(l["bx"]) - float(l["ax"])
			var dz: float = float(l["bz"]) - float(l["az"])
			var den := dx * dx + dz * dz
			if den == 0.0:
				den = 1.0
			var t := maxf(0.0, minf(1.0, ((x - float(l["ax"])) * dx + (z - float(l["az"])) * dz) / den))
			if DmSimMath.hypot(x - (float(l["ax"]) + dx * t), z - (float(l["az"]) + dz * t)) < r + LANE_HALF:
				return true
		return false
	var clear_of_props := func(x: float, z: float, r: float) -> bool:
		for p: Dictionary in props:
			if not (DmSimMath.hypot(float(p["x"]) - x, float(p["z"]) - z) > r):
				return false
		for k: Dictionary in keep_clear:
			if not (DmSimMath.hypot(float(k["x"]) - x, float(k["z"]) - z) > float(k["r"]) + r * 0.5):
				return false
		return true
	var fits := func(room: Dictionary, x: float, z: float, r: float) -> bool:
		var rr: Dictionary = room["rect"]
		return x > float(rr["x0"]) + r + 0.8 and x < float(rr["x1"]) - r - 0.8 and z > float(rr["z0"]) + r + 0.8 and z < float(rr["z1"]) - r - 0.8 \
			and not near_door.call(x, z) and not on_lane.call(x, z, r) and clear_of_props.call(x, z, r)
	var low_walls: Array = []
	for room: Dictionary in base["rooms"]:
		if not room["active"] or int(room["id"]) == int(base["startRoom"]):
			continue
		var rr: Dictionary = room["rect"]
		var hw := (float(rr["x1"]) - float(rr["x0"])) / 2.0
		var hh := (float(rr["z1"]) - float(rr["z0"])) / 2.0
		var spots: Array = []
		for s in [[-1, -1], [1, 1], [1, -1], [-1, 1]]:
			spots.append([float(room["cx"]) + s[0] * (hw - 2.4), float(room["cz"]) + s[1] * (hh - 2.4)])
		var i := spots.size() - 1
		while i > 0:
			var j := int(floorf(rng.next() * (i + 1)))
			var tmp = spots[i]
			spots[i] = spots[j]
			spots[j] = tmp
			i -= 1
		for s in [[-0.5, -0.5], [0.5, 0.5], [0.5, -0.5], [-0.5, 0.5], [0.0, 0.7], [0.0, -0.7]]:
			spots.append([float(room["cx"]) + s[0] * hw, float(room["cz"]) + s[1] * hh])
		var n := 0
		for sp: Array in spots:
			if n >= 2:
				break
			var x: float = sp[0]
			var z: float = sp[1]
			var skip: bool = near_door.call(x, z, -0.4)
			if not skip:
				for k: Dictionary in keep_clear:
					if DmSimMath.hypot(float(k["x"]) - x, float(k["z"]) - z) < 1.6:
						skip = true
						break
			if skip:
				continue
			breaches.append({"x": x, "z": z, "room": room["id"]})
			keep_clear.append({"x": x, "z": z, "r": 1.4})
			n += 1
	for room: Dictionary in base["rooms"]:
		if not room["active"]:
			continue
		var rr: Dictionary = room["rect"]
		var cx: float = room["cx"]
		var cz: float = room["cz"]
		if attempt >= 0:
			for adj in room["adj"]:
				if int(adj["to"]) < int(room["id"]):
					continue
				var d: Dictionary = doors[int(adj["door"])]
				var dx: float = d["x"]
				var dz: float = d["z"]
				var side: Dictionary
				var other: Dictionary
				if d["wall"] == "x":
					side = {"x": dx + 0.9, "z": dz - DOOR_W / 2.0 - 0.5}
					other = {"x": dx - 0.9, "z": dz + DOOR_W / 2.0 + 0.5}
				else:
					side = {"x": dx - DOOR_W / 2.0 - 0.5, "z": dz + 0.9}
					other = {"x": dx + DOOR_W / 2.0 + 0.5, "z": dz - 0.9}
				P.call("grave_lantern", side["x"], side["z"], 0.0)
				P.call("grave_lantern", other["x"], other["z"], 0.0)
		if attempt < 0:
			continue
		var w := float(rr["x1"]) - float(rr["x0"])
		var h := float(rr["z1"]) - float(rr["z0"])
		var special: bool = int(room["id"]) == int(base["startRoom"]) or int(room["id"]) == int(base["stairRoom"]) or (base["chestRoom"] != null and int(room["id"]) == int(base["chestRoom"]))
		match room["kind"]:
			"pillars":
				for s in [[-1, -1], [1, -1], [-1, 1], [1, 1]]:
					var x: float = cx + s[0] * w * 0.27
					var z: float = cz + s[1] * h * 0.27
					if fits.call(room, x, z, 0.85):
						P.call("pillar", x, z, 0.0)
			"crypt":
				if not special:
					for o in [[0.0, -1.0], [-3.6, 2.4], [3.6, 2.4], [-3.6, -2.4], [3.6, -2.4]]:
						if fits.call(room, cx + o[0], cz + o[1], 1.4):
							P.call("sarcophagus", cx + o[0], cz + o[1], PI / 2.0)
							break
					for o in [[-3.6, -3.0], [3.6, -3.0], [-3.6, 3.0], [3.6, 3.0]]:
						if fits.call(room, cx + o[0], cz + o[1], 0.4):
							P.call("bone_candelabrum", cx + o[0], cz + o[1], 0.0)
				else:
					for o in [[-4.0, -3.4], [4.0, -3.4]]:
						if fits.call(room, cx + o[0], cz + o[1], 0.4):
							P.call("bone_candelabrum", cx + o[0], cz + o[1], 0.0)
			"cages":
				for k in 3:
					var x := cx + (rng.next() - 0.5) * (w - 6.0)
					var z := cz + (rng.next() - 0.5) * (h - 6.0)
					if fits.call(room, x, z, 0.8):
						P.call("gibbet_cage", x, z)
			"bones":
				for k in 4:
					var x := cx + (rng.next() - 0.5) * (w - 4.0)
					var z := cz + (rng.next() - 0.5) * (h - 4.0)
					if fits.call(room, x, z, 0.8):
						var kind := "bone_pile" if rng.next() < 0.6 else "tombstone_round"
						P.call(kind, x, z)
			"ossuary":
				for k in 2:
					var x := cx + (rng.next() - 0.5) * (w - 6.0)
					var z := cz + (rng.next() - 0.5) * (h - 6.0)
					if fits.call(room, x, z, 1.2):
						P.call("coffin_stack" if k % 2 == 1 else "tombstone_cross", x, z)
			_:
				pass
		var scatter := DmMath.js_round((2.0 + floorf(rng.next() * 3.0)) * density)
		for k in scatter:
			var x := float(rr["x0"]) + 1.6 + rng.next() * (w - 3.2)
			var z := float(rr["z0"]) + 1.6 + rng.next() * (h - 3.2)
			if fits.call(room, x, z, 0.9):
				var kind: String
				if rng.next() < 0.55:
					kind = "bone_pile"
				else:
					kind = "tombstone_round" if rng.next() < 0.5 else "candles"
				P.call(kind, x, z)
		var covers := DmMath.js_round((2.0 if (room["kind"] == "plain" and not special) else 1.0) * density * (0.5 + rng.next()))
		for k in covers:
			var horizontal := rng.next() < 0.5
			var ln := 3.2
			var x := cx + (rng.next() - 0.5) * (w - 8.0)
			var z := cz + (rng.next() - 0.5) * (h - 7.0)
			var x0 := x - ln / 2.0 if horizontal else x
			var x1 := x + ln / 2.0 if horizontal else x
			var z0 := z if horizontal else z - ln / 2.0
			var z1 := z if horizontal else z + ln / 2.0
			var probes: Array = [[x0, z0], [x1, z1], [(x0 + x1) / 2.0, (z0 + z1) / 2.0]]
			var all_fit := true
			for pr: Array in probes:
				if not fits.call(room, pr[0], pr[1], 1.1):
					all_fit = false
					break
			if not all_fit:
				continue
			var near := false
			for o: Dictionary in low_walls:
				if DmSimMath.hypot((float(o["x0"]) + float(o["x1"])) / 2.0 - x, (float(o["z0"]) + float(o["z1"])) / 2.0 - z) < 4.0:
					near = true
					break
			if near:
				continue
			low_walls.append({"x0": x0, "z0": z0, "x1": x1, "z1": z1, "height": 1.1, "thickness": 0.9, "texture": "skull_wall", "area": "depths"})
	var out := base.duplicate()
	out["walls"] = walls + low_walls
	out["props"] = props
	out["breaches"] = breaches
	return out
