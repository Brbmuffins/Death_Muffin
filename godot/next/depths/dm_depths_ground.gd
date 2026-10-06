class_name DmDepthsGround
extends Node
## The Depths floor as ground: the picture (DmWorldBuilder.build_depths_floor / clear_depths_floor, the existing look), the navmesh of THIS floor
## (one NavigationRegion3D, its mesh swapped per floor), and the wall / prop colliders enemies slide on.
##
## The world builder bakes a sample Depths floor into "area:depths" at build and keeps its walls' colliders in the shared Colliders body; both are
## wrong for a generated floor, so setup() removes the sample colliders (inside the Depths rect) and this node's own region stands in while a run
## is on (the builder's region stays disabled: `depths_open` is never set).
## Cost per floor is measured: `build_ms` (picture + colliders + bake: all of it on the main thread, before the first await), `bake_ms`, `nav_ms` (+ the server merging the region).

const GROW := 0.55               ## the builder's obstruction grow (the baker does not inflate projected obstructions)
const WALL_H := 3.0

var game: Node                   ## DmNextGame
var region: NavigationRegion3D
var colliders: StaticBody3D
var build_ms: int = 0
var bake_ms: int = 0              ## the navmesh bake (main thread)
var nav_ms: int = 0               ## bake + the navigation server merging the region (until the hero can stand on it)
var floor_data: Dictionary = {}

var _rect: Dictionary
var _sample_freed: int = 0


func setup(game_: Node) -> void:
	game = game_
	_rect = DmContent.area("depths")["rect"]
	region = NavigationRegion3D.new()
	region.name = "DepthsNav"
	region.enabled = false
	game.world.add_child(region)
	colliders = StaticBody3D.new()
	colliders.name = "DepthsColliders"
	game.world.add_child(colliders)
	# The sample floor's colliders: invisible walls in the middle of generated rooms.
	var shared: Node = game.world.builder.get_node_or_null("Colliders")
	if shared != null:
		for c in shared.get_children():
			var cs := c as CollisionShape3D
			if cs != null and cs.position.x >= float(_rect["x0"]) and cs.position.x <= float(_rect["x1"]) and cs.position.z >= float(_rect["z0"]) and cs.position.z <= float(_rect["z1"]):
				cs.queue_free()
				_sample_freed += 1


## Draw and bake floor `f`; returns when the navigation map knows it (the hero can stand and walk on it).
func build(f: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	clear_colliders()
	floor_data = f
	region.enabled = false
	game.world.builder.build_depths_floor(f)
	_make_colliders(f)
	var src := _source(f)
	var nm := _nav_mesh()
	var map := region.get_world_3d().navigation_map
	var iter0 := NavigationServer3D.map_get_iteration_id(map)
	var t1 := Time.get_ticks_msec()
	NavigationServer3D.bake_from_source_geometry_data(nm, src)   # ~6 ms for a floor (measured): cheaper than a thread round trip
	bake_ms = Time.get_ticks_msec() - t1
	region.navigation_mesh = nm
	region.enabled = true
	build_ms = Time.get_ticks_msec() - t0   # everything the main thread did before its first await
	# The server merges the region on its own clock: wait for a map iteration that sees it, then for walkable ground at the way in.
	var probes: Array[Vector3] = [Vector3(float(f["start"]["x"]), 0.0, float(f["start"]["z"])), Vector3(float(f["stairDown"]["x"]), 0.0, float(f["stairDown"]["z"]) + 1.6)]
	var frames := 0
	while frames < 120:
		await game.get_tree().physics_frame
		frames += 1
		if NavigationServer3D.map_get_iteration_id(map) > iter0:
			var ok := true   # both probes (a stale mesh of the last floor would not cover both)
			for pr in probes:
				var q := NavigationServer3D.map_get_closest_point(map, pr)
				ok = ok and Vector2(q.x - pr.x, q.z - pr.z).length() < 0.6
			if ok:   # and the graph connects them (the map's edges are rebuilt in the same sync as its polygons, but ask)
				var path := NavigationServer3D.map_get_path(map, probes[0], probes[1], true)
				ok = path.size() >= 2 and Vector2(path[path.size() - 1].x - probes[1].x, path[path.size() - 1].z - probes[1].z).length() < 1.0
			if ok:
				break
	nav_ms = Time.get_ticks_msec() - t0


## The run is over: the picture is freed, the region and colliders go away.
func clear() -> void:
	region.enabled = false
	clear_colliders()
	floor_data = {}
	game.world.builder.clear_depths_floor()


func clear_colliders() -> void:
	for c in colliders.get_children():
		colliders.remove_child(c)
		c.queue_free()


# ---- navmesh source -------------------------------------------------------------------------------------------------------------

func _source(f: Dictionary) -> NavigationMeshSourceGeometryData3D:
	var src := NavigationMeshSourceGeometryData3D.new()
	var faces := PackedVector3Array()
	for r in f["rooms"]:
		if r["active"]:
			_quad(faces, r["rect"]["x0"], r["rect"]["z0"], r["rect"]["x1"], r["rect"]["z1"])
	for d in f["doors"]:
		var hx := 0.9 if absf(float(d["dir"]["x"])) > 0.5 else 2.3
		var hz := 0.9 if absf(float(d["dir"]["z"])) > 0.5 else 2.3
		_quad(faces, float(d["x"]) - hx, float(d["z"]) - hz, float(d["x"]) + hx, float(d["z"]) + hz)
	src.add_faces(faces, Transform3D.IDENTITY)
	for o: DmNavObstacle in DmDepthsFloor.floor_obstacles(f):
		src.add_projected_obstruction(_outline(o), -0.5, 3.0, true)
	return src


static func _quad(out: PackedVector3Array, x0: float, z0: float, x1: float, z1: float) -> void:
	var a := Vector3(x0, 0, z0)
	var b := Vector3(x1, 0, z0)
	var c := Vector3(x1, 0, z1)
	var d := Vector3(x0, 0, z1)
	out.append_array(PackedVector3Array([a, b, c, a, c, d]))


## A circle (props, stairs, chest) grows by GROW like the builder's; walls are baked as they are.
func _outline(o: DmNavObstacle) -> PackedVector3Array:
	if o.is_circle:
		var pts := PackedVector3Array()
		var r := o.r + GROW
		for i in 10:
			var a := TAU * i / 10.0
			pts.append(Vector3(o.x + cos(a) * r, 0, o.z + sin(a) * r))
		return pts
	return PackedVector3Array([Vector3(o.x0, 0, o.z0), Vector3(o.x1, 0, o.z0), Vector3(o.x1, 0, o.z1), Vector3(o.x0, 0, o.z1)])


func _nav_mesh() -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.agent_radius = 0.5
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.agent_max_slope = 45.0
	nm.region_min_size = 1.0
	return nm


# ---- colliders ------------------------------------------------------------------------------------------------------------------

## Walls and solid props, as the sim's obstacle boxes / circles (the generated floor's walls are drawn without colliders by the builder).
func _make_colliders(f: Dictionary) -> void:
	for o: DmNavObstacle in DmDepthsFloor.floor_obstacles(f):
		var cs := CollisionShape3D.new()
		if o.is_circle:
			var cy := CylinderShape3D.new()
			cy.radius = o.r
			cy.height = WALL_H
			cs.shape = cy
			cs.position = Vector3(o.x, WALL_H / 2.0, o.z)
		else:
			var bs := BoxShape3D.new()
			bs.size = Vector3(o.x1 - o.x0, WALL_H, o.z1 - o.z0)
			cs.shape = bs
			cs.position = Vector3((o.x0 + o.x1) / 2.0, WALL_H / 2.0, (o.z0 + o.z1) / 2.0)
		colliders.add_child(cs)
