class_name DmNextWorld
extends Node3D
## The slice's world: the existing DmWorldBuilder (floors, walls, props, lights, fog, the per-area navmesh regions it bakes from the same
## obstacles as godot/data/sim/world.json + its wall boxes) plus the world dressing, with the per-frame streaming/occlusion calls. Everything here is presentation + the navigation map; no gameplay.
##
## Navigation: DmWorldBuilder bakes one NavigationRegion3D per area and per door corridor at build() (NavigationServer3D.bake_from_source_
## geometry_data, projected obstructions for every wall/prop/node/pond), joined by NavigationLinks. `bake_ms` is that cost. The Chapterhouse,
## the Hollow Graves and the door between them are always enabled.

var builder: DmWorldBuilder
var dressing: DmWorldDressing
var focus: Node3D            ## follows the local hero (dressing: mist, braziers, wading ripples)
var build_ms: int = 0
var bake_ms: int = 0
var sync_ms: int = 0         ## the first navigation-map sync (wait_nav_ready)
var area_id: String = ""

var _map: RID
var _nav_ok := false
## Height of the baked navmesh above the floor (0.5 here: agent_max_climb + cell offsets). Agents standing at y = 0 would be 0.5 m from every
## path point, exactly their path_desired_distance, and flip between "reached" and "not reached" every tick: DmWaveDirector hands this to each
## enemy's NavigationAgent3D.path_height_offset.
var nav_y: float = 0.0


func build(with_dressing: bool = true) -> void:
	var t0 := Time.get_ticks_msec()
	builder = DmWorldBuilder.new()
	builder.name = "Builder"
	builder.npcs_enabled = false
	add_child(builder)
	builder.build(DmData.world())
	focus = Node3D.new()
	focus.name = "Focus"
	add_child(focus)
	if with_dressing:
		dressing = DmWorldDressing.attach(builder, focus)
	_map = get_world_3d().navigation_map
	build_ms = Time.get_ticks_msec() - t0
	bake_ms = builder.nav_bake_ms
	area_id = "chapterhouse"


## The navigation server registers the baked regions and syncs the map on its own clock (a few frames to ~0.5 s the first time): wait for it
## here, during loading, so no gameplay frame pays for it and the first click already has a real path. Returns false on timeout.
func wait_nav_ready(timeout_s: float = 5.0) -> bool:
	var t1 := Time.get_ticks_msec()
	while not nav_ready() and (Time.get_ticks_msec() - t1) < timeout_s * 1000.0:
		await get_tree().process_frame
	sync_ms = Time.get_ticks_msec() - t1
	return nav_ready()


func camera_config() -> Dictionary:
	return DmData.world()["camera"]


func area_at(x: float, z: float) -> String:
	return builder.area_at(x, z) if builder != null else ""


func enter_area(id: String) -> void:
	area_id = id
	if builder != null:
		builder.set_area(id)


## Per frame, local hero only (streaming / occlusion for the world).
func update(cam: DmCameraRig, hero: Vector3, dt: float) -> void:
	if builder == null:
		return
	focus.position = Vector3(hero.x, 0.0, hero.z)
	builder.update_occlusion(cam, hero)
	builder.update_streaming(cam.focus.x, cam.focus.z)
	builder.tick_light_lod(cam.focus.x, cam.focus.z, dt)
	builder.update_shadow_cells(hero.x, hero.z, dt)


# ---- navigation -------------------------------------------------------------------------------------------------------------

func nav_ready() -> bool:
	if _nav_ok:
		return true
	if builder == null or not _map.is_valid() or NavigationServer3D.map_get_iteration_id(_map) == 0:
		return false
	# The server merges regions over several iterations: ready = every enabled area's centre has walkable ground within 5 m (an area that
	# is not merged yet answers from the nearest merged one, tens of metres away).
	for id in builder.world.order:
		var reg: NavigationRegion3D = builder.nav_regions.get("area:" + String(id))
		if reg == null or not reg.enabled:
			continue
		var r: Dictionary = builder.area_rects[id]
		var c := Vector3((float(r.x0) + float(r.x1)) * 0.5, 0.0, (float(r.z0) + float(r.z1)) * 0.5)
		var q := NavigationServer3D.map_get_closest_point(_map, c)
		if Vector2(q.x - c.x, q.z - c.z).length() > 5.0:
			return false
		nav_y = q.y
	_nav_ok = true
	return true


## Walkable path (world points) between two points; the end is snapped to the nearest walkable point.
func nav_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	return NavigationServer3D.map_get_path(_map, from, to, true)


## The nearest walkable point (y forced to 0). Used both to keep the hero off walls (sliding) and to place spawns.
func nav_closest(p: Vector3) -> Vector3:
	var c := NavigationServer3D.map_get_closest_point(_map, p)
	return Vector3(c.x, 0.0, c.z)


## `p` itself when walkable (within 2 cm of the mesh), else the nearest walkable point: walking into a wall slides along it.
func nav_clamp(p: Vector3) -> Vector3:
	var c := nav_closest(p)
	return p if Vector2(c.x - p.x, c.z - p.z).length_squared() < 0.0004 else c
