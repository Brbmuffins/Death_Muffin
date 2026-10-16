class_name DmNextWorld
extends Node3D
## The game's world on the rebuilt client: the area scenes built offline from godot/data/slice/world.json (client/areas/<id>.tscn, built by
## tools/rebuild/build-areas.sh) in place of the runtime `DmWorldBuilder` build that godot/next/next_world.gd makes. It gives the code that expects
## today's world object the same small API: `area_at`, the navigation helpers (`nav_ready`, `nav_path`, `nav_closest`, `nav_clamp`), `enter_area`,
## `update`, `camera_config`, plus `nav_map()` for the combat core and `spawn_point()` for the hero.
##
## What an area scene does not carry (client/README.md "Areas") is made here, for now, by a `DmWorldBuilder` used for its lights only: the
## environment, fog, the moon and the rim light of the area, exactly as today's builder sets them (a later world scene owns them). The builder builds
## no floor, wall or prop (`builder` is only that light holder). No world dressing (mist, braziers, ripples) and no streaming or occlusion yet.
##
## Only the areas listed in `build` exist: the Hollow Graves in this step. Doors to areas that are not loaded lead nowhere (the always-open door of the
## Graves has navmesh to its end).

const AREA_DIR := "res://areas/"

var builder: DmWorldBuilder            ## lights only (see above); not today's full builder
var focus: Node3D                      ## follows the local hero (the world dressing's anchor when it comes)
var build_ms: int = 0
var bake_ms: int = 0                   ## the navmeshes are baked offline: 0
var sync_ms: int = 0                   ## the first navigation-map sync (wait_nav_ready)
var area_id: String = ""
var loaded: Array[String] = []         ## area ids with a scene, in world order
## Height of the baked navmesh above the floor, read when the map is ready. (Today it fed each enemy's NavigationAgent3D; the core steers its own bodies.)
var nav_y: float = 0.0

var _map: RID
var _nav_ok := false
var _scenes := {}                      ## area id -> its scene root
var _rects := {}                       ## area id -> {x0, z0, x1, z1} from world.json


## Loads the area scenes and the area lighting. `area_ids`: which areas exist in this game (world order is kept). `with_lights`: the environment and moon
## (tests without a screen may skip them).
func build(area_ids: Array = ["graves"], with_lights: bool = true) -> void:
	var t0 := Time.get_ticks_msec()
	var data: Dictionary = DmData.world()
	for id in data["order"]:
		if not area_ids.has(String(id)):
			continue
		var packed: PackedScene = load(AREA_DIR + "%s.tscn" % id)
		var scene: Node3D = packed.instantiate()
		scene.name = "area_%s" % id
		add_child(scene)
		_scenes[String(id)] = scene
		_rects[String(id)] = data["areas"][id]["rect"]
		loaded.append(String(id))
	focus = Node3D.new()
	focus.name = "Focus"
	add_child(focus)
	_map = get_world_3d().navigation_map
	if OS.get_environment("DM_SYNC_NAV") == "1":   # as the builder: tests under --fixed-fps outrun the navigation server's worker thread
		NavigationServer3D.map_set_use_async_iterations(_map, false)
	if with_lights:
		builder = DmWorldBuilder.new()
		builder.name = "Lights"
		add_child(builder)
		builder.world = data
		builder._make_environment()
		builder.set_area(loaded[0])
	area_id = loaded[0]
	build_ms = Time.get_ticks_msec() - t0


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


## The area at a ground point ("" = outside every loaded area, a door corridor included): the rect test of the builder's `area_at`.
func area_at(x: float, z: float) -> String:
	for id in loaded:
		var r: Dictionary = _rects[id]
		if x >= r.x0 and x <= r.x1 and z >= r.z0 and z <= r.z1:
			return id
	return ""


func area_rect(id: String) -> Dictionary:
	return _rects.get(id, {})


## The area's ground and its door corridors: the combat core's bounds (its spatial grid) and the crowd's custom bounds.
func bounds(pad: float = 12.0) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for id in loaded:
		var r: Dictionary = _rects[id]
		lo = Vector2(minf(lo.x, float(r.x0)), minf(lo.y, float(r.z0)))
		hi = Vector2(maxf(hi.x, float(r.x1)), maxf(hi.y, float(r.z1)))
	return Rect2(lo - Vector2(pad, pad), hi - lo + Vector2(pad, pad) * 2.0)


## A walkable point just inside the area's door to the Chapterhouse (the Chapterhouse is not loaded yet): where a hero starts, and where a fallen
## one gets up. The door's centre across, the area's edge facing it less 3 m.
func spawn_point(id: String = "") -> Vector3:
	var a := id if id != "" else area_id
	var r: Dictionary = _rects[a]
	var x := (float(r.x0) + float(r.x1)) * 0.5
	var z := float(r.z1) - 3.0
	for d in DmContent.get_export("areas", "DOORS"):
		if String(d["b"]) == a and String(d["a"]) == "chapterhouse":
			x = (float(d["rect"]["x0"]) + float(d["rect"]["x1"])) * 0.5
	var p := Vector3(x, 0.0, z)
	return nav_closest(p) if nav_ready() else p


## Today's `enter_area`: the lighting follows the hero into the area.
func enter_area(id: String) -> void:
	area_id = id
	if builder != null:
		builder.set_area(id)


## Per frame, local hero only (streaming / occlusion for the world, when they come).
func update(_cam: DmCameraRig, hero: Vector3, _dt: float) -> void:
	if focus != null:
		focus.position = Vector3(hero.x, 0.0, hero.z)


# ---- navigation -------------------------------------------------------------------------------------------------------------

## The navigation map the area scenes' regions live on (the combat core's `set_nav_map`).
func nav_map() -> RID:
	return _map


func nav_ready() -> bool:
	if _nav_ok:
		return true
	if loaded.is_empty() or not _map.is_valid() or NavigationServer3D.map_get_iteration_id(_map) == 0:
		return false
	# The server merges regions over several iterations: ready = every enabled area's centre has walkable ground within 5 m (an area that
	# is not merged yet answers from the nearest merged one, tens of metres away).
	for id in loaded:
		var reg := _scenes[id].get_node_or_null("Navigation/area_%s" % id) as NavigationRegion3D
		if reg == null or not reg.enabled:
			continue
		var r: Dictionary = _rects[id]
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
