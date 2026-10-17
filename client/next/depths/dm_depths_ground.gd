class_name DmDepthsGround
extends Node
## The Depths floor as ground, made at run time: the picture (the lights builder's `build_depths_floor` / `clear_depths_floor`, the existing look, drawn into the world's
## `depths_root`) and the navmesh of THIS floor (one NavigationRegion3D, its mesh swapped per floor).
##
## On the combat core (client/code.list "Ported"). The other areas are scenes built offline; a Depths floor is generated per run, so everything an area scene carries is
## made here, in two steps so the hero never waits on a bake:
##   `prepare(f)`  bakes the floor's navmesh from its rooms, doors and obstacles on a worker thread (NavigationServer3D, the builder's settings) while the old floor still stands;
##   `show(f)`     swaps the picture, puts the baked mesh on the floor's region (on the navigation map) and hands the core its copy (DmNextWorld.attach_floor);
##   `merged()`    waits until the navigation server has merged the region, so a path from the way in to the stair already exists (the core's own copy answers at once).
## No physics colliders: the hero has no body and the core keeps bodies on the navmesh, whose projected obstructions are the walls and props (the area scenes' colliders are
## not read by anything either).
## Cost per floor is measured: `build_ms` (the main thread's part: picture, region and the core's copy), `bake_ms` (the worker's bake, waited for), `nav_ms` (everything, to the merge).

const GROW := 0.55               ## the builder's obstruction grow (the baker does not inflate projected obstructions)
const BAKE_TIMEOUT_MS := 20000   ## a bake that takes longer than this is abandoned (the floor is baked again on the main thread)

var game: DmNextGame
var region: NavigationRegion3D
var build_ms: int = 0
var bake_ms: int = 0              ## the navmesh bake (the worker thread's time, waited for)
var nav_ms: int = 0               ## prepare + show + the navigation server merging the region (until the hero can path on it)
var floor_data: Dictionary = {}
var async_ok := false             ## the last bake came from the worker thread (false: the main thread made it after the worker did not deliver)

var _baked: NavigationMesh        ## prepare's result, waiting for show
var _iter0 := 0                   ## the map's iteration when the region was enabled: merged() waits for a later one
var _t0 := 0


func setup(game_: DmNextGame) -> void:
	game = game_
	region = NavigationRegion3D.new()
	region.name = "DepthsNav"
	region.enabled = false
	game.world.add_child(region)


## Bake floor `f`'s navmesh off the main thread; the old floor (picture and region) is untouched. False when the bake gave no ground.
func prepare(f: Dictionary) -> bool:
	_t0 = Time.get_ticks_msec()
	var src := _source(f)
	var nm := _nav_mesh()
	var t1 := Time.get_ticks_msec()
	NavigationServer3D.bake_from_source_geometry_data_async(nm, src)
	while NavigationServer3D.is_baking_navigation_mesh(nm) and Time.get_ticks_msec() - t1 < BAKE_TIMEOUT_MS:
		await game.get_tree().physics_frame
	DmThreadGuard.assert_main("the Depths navmesh taken from its bake")   # (the server applies a finished bake in its main-thread sync: nothing here runs on the bake's thread)
	async_ok = not NavigationServer3D.is_baking_navigation_mesh(nm) and nm.get_polygon_count() > 0
	if not async_ok:
		nm = _nav_mesh()   # the worker did not deliver: the same bake here, on a fresh mesh
		NavigationServer3D.bake_from_source_geometry_data(nm, src)
	bake_ms = Time.get_ticks_msec() - t1
	_baked = nm
	return nm.get_polygon_count() > 0


## Swap to floor `f` (prepared): draw it, put its navmesh on the region and give the core its copy. The hero may stand on it from here.
func show(f: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	floor_data = f
	region.enabled = false
	var builder := game.world.builder
	if builder != null:
		builder.build_depths_floor(f)
		for e: Dictionary in builder.prop_lights:   # the builder leaves a prop light off until its light budget (Compatibility's) picks it: a Forward+ floor lights them all
			e["node"].visible = true
	_iter0 = NavigationServer3D.map_get_iteration_id(region.get_world_3d().navigation_map)
	region.navigation_mesh = _baked
	region.enabled = true
	_baked = null
	game.world.attach_floor(region)
	build_ms = Time.get_ticks_msec() - t0


## Returns once the navigation map knows floor `f` (a path from the way in to the stair exists): the server merges a region on its own clock, a few frames after it is enabled.
func merged() -> void:
	var f := floor_data
	var map := region.get_world_3d().navigation_map
	var probes: Array[Vector3] = [Vector3(float(f["start"]["x"]), 0.0, float(f["start"]["z"])), Vector3(float(f["stairDown"]["x"]), 0.0, float(f["stairDown"]["z"]) + 1.6)]
	var frames := 0
	while frames < 120 and not floor_data.is_empty():
		await game.get_tree().physics_frame
		frames += 1
		if NavigationServer3D.map_get_iteration_id(map) > _iter0:
			var ok := true   # both probes (a stale mesh of the last floor would not cover both)
			for pr in probes:
				var q := NavigationServer3D.map_get_closest_point(map, pr)
				ok = ok and Vector2(q.x - pr.x, q.z - pr.z).length() < 0.6
			if ok:   # and the graph connects them (the map's edges are rebuilt in the same sync as its polygons, but ask)
				var path := NavigationServer3D.map_get_path(map, probes[0], probes[1], true)
				ok = path.size() >= 2 and Vector2(path[path.size() - 1].x - probes[1].x, path[path.size() - 1].z - probes[1].z).length() < 1.0
			if ok:
				break
	nav_ms = Time.get_ticks_msec() - _t0


## The run is over: the picture is freed, the region goes off the map and out of the core.
func clear() -> void:
	region.enabled = false
	_baked = null
	floor_data = {}
	game.world.detach_floor()
	if game.world.builder != null:
		game.world.builder.clear_depths_floor()


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
