class_name DmNextWorld
extends Node3D
## The game's world on the rebuilt client: the area scenes built offline from godot/data/slice/world.json (client/areas/<id>.tscn, built by
## tools/rebuild/build-areas.sh) in place of the runtime `DmWorldBuilder` build that godot/next/next_world.gd makes. It gives the code that expects
## today's world object the same small API: `area_at`, the navigation helpers (`nav_ready`, `nav_path`, `nav_closest`, `nav_clamp`), `enter_area`,
## `update`, `camera_config`, the seals and doors of today's builder (`set_unlocked`, `set_door_open`, `gates`, `nav_regions`, `nav_links`), plus `nav_map()` for the
## combat core and `spawn_point()` for the hero.
##
## What an area scene does not carry (client/README.md "Areas") is made here, for now, by a `DmWorldBuilder` used for its lights only: the
## environment, fog, the moon and the rim light of the area, exactly as today's builder sets them (a later world scene owns them). The builder builds
## no floor, wall or prop (`builder` is only that light holder, and carries `area_nodes` and `node_views` for the gathering views). No world dressing (mist, braziers, ripples) and no streaming or occlusion yet.
##
## Every area but the Depths exists by default, as today's builder builds them all; `build` takes a shorter list (tests: the Graves alone). A door lies in the scenes of
## both its areas: the first one loaded keeps it, the other copy is dropped before it enters the tree. Gates start closed; `set_unlocked` opens a door when both of its
## areas are unlocked and loaded, and the area's own navmesh is on only while it is unlocked (the Graves' door to the Chapterhouse is always open).
##
## The Depths are the one area with no scene: an instance, its floors generated and baked at run time (next/depths/dm_depths_ground.gd). Its rect is known from the start
## (`area_rect` knows it; `bounds` covers it when the Warren, whose stair leads there, is in the world); `open_instance("depths", true)` makes it an area (`area_at`) while a run stands on it, and `attach_floor / detach_floor` give the
## floor's navmesh region to the combat core (its own copy, replaced floor by floor) the way `bind_core` gave it the others. The floor's picture is drawn into `depths_root`
## by the lights builder's `build_depths_floor` (no see-through cutout yet, like the other areas).

signal door_opened(id: String)         ## a door rose (a seal broke here, or on the host while a guest is in its party): the gate sound is DmAudioHooks'; never at a quiet load

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

## Today's builder's seal state, same names (DmChapterhouse reads them): unlocked area ids, door id -> {bars, collider, open}, "area:<id>" / "door:<id>" ->
## its NavigationRegion3D, door id -> its two NavigationLink3D.
var unlocked: Dictionary = {}
var gates: Dictionary = {}
var nav_regions: Dictionary = {}
var nav_links: Dictionary = {}

## The instance areas (the Depths): their rects, whether a run has one open, and the node a runtime floor is drawn into.
var depths_open := false
var depths_root: Node3D                ## where `builder.build_depths_floor` draws the generated floor (null in a world with no lights)

var _map: RID
var _nav_ok := false
var _core: RefCounted                  ## the combat core once bound (bind_core): it keeps its own copy of the navmesh
var _core_region := {}                 ## nav_regions key -> the core's region index
var _floor_region: NavigationRegion3D  ## the Depths floor's region while a floor stands (attach_floor)
var _core_floor := -1                  ## the core's region index of the Depths floor (one index, its polygons replaced per floor), -1 = none yet
var _scenes := {}                      ## area id -> its scene root
var _rects := {}                       ## area id -> {x0, z0, x1, z1} from world.json


## Every converted area (all but the instanced Depths), in world order.
static func every_area() -> Array:
	var out: Array = []
	for id in DmData.world()["order"]:
		if not bool(DmData.world()["areas"][id]["instance"]):
			out.append(String(id))
	return out


## Loads the area scenes and the area lighting. `area_ids`: which areas exist in this game (world order is kept; empty = every area). `with_lights`: the
## environment and moon (tests without a screen may skip them).
func build(area_ids: Array = [], with_lights: bool = true) -> void:
	var t0 := Time.get_ticks_msec()
	var data: Dictionary = DmData.world()
	var want := area_ids if not area_ids.is_empty() else every_area()
	for id in data["order"]:
		if not want.has(String(id)):
			continue
		var packed: PackedScene = load(AREA_DIR + "%s.tscn" % id)
		var scene: Node3D = packed.instantiate()
		scene.name = "area_%s" % id
		_drop_door_copies(scene)
		add_child(scene)
		_scenes[String(id)] = scene
		_rects[String(id)] = data["areas"][id]["rect"]
		loaded.append(String(id))
		_collect_doors(scene, String(id))
	_rects["depths"] = data["areas"]["depths"]["rect"]
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
		builder.occlusion_enabled = false   # the see-through cutout comes with the look pass (client/README.md "Areas")
		builder._make_environment()
		builder.set_area(loaded[0])
		_register_nodes()
		depths_root = Node3D.new()
		depths_root.name = "area_depths"
		add_child(depths_root)
		builder.area_nodes["depths"] = depths_root
	area_id = loaded[0]
	set_unlocked([])
	build_ms = Time.get_ticks_msec() - t0


## The two members of today's builder that the copied gathering views read (`DmNodeViews.setup`): `area_nodes` (area id -> its root) and `node_views` (gathering node
## id -> its holder under the scene's `GatherNodes`), so a node swaps to its spent look on the area scene's own props.
func _register_nodes() -> void:
	for id: String in loaded:
		var scene: Node3D = _scenes[id]
		builder.area_nodes[id] = scene
		for holder: Node in scene.get_node("GatherNodes").get_children():
			builder.node_views[String(holder.name)] = holder


## A door already kept by an earlier area's scene: drop this scene's copy (its floor and gate, its navmesh region and links) before it enters the tree.
func _drop_door_copies(scene: Node3D) -> void:
	for d: Node in scene.get_node("Doors").get_children():
		var id := String(d.name)
		if not nav_regions.has("door:" + id):
			continue
		d.free()
		var nav := scene.get_node("Navigation")
		nav.get_node("door_" + id).free()
		for k in 2:
			nav.get_node("link_%s_%d" % [id, k]).free()


func _collect_doors(scene: Node3D, id: String) -> void:
	var nav := scene.get_node("Navigation")
	nav_regions["area:" + id] = nav.get_node("area_" + id)
	for d: Node in scene.get_node("Doors").get_children():
		var did := String(d.name)
		var gate := d.get_node_or_null("gate")
		if gate != null:
			var col := gate.get_node("body/collider") as CollisionShape3D
			gates[did] = {"bars": gate.get_node("bars"), "collider": col, "open": col.disabled}   # a door world.json lists as open starts open in its scene
		nav_regions["door:" + did] = nav.get_node("door_" + did)
		nav_links[did] = [nav.get_node("link_%s_0" % did), nav.get_node("link_%s_1" % did)]


## The combat core keeps its own copy of every navmesh region (DmCore.nav_add_region, a grid of triangles) for its per-tick "keep to the navmesh" step and
## for nav_closest: the navigation server's closest-point query walks every polygon of the map, and with every area loaded that cost 7x the Graves' alone.
## Region switches (seals, doors) reach both.
func bind_core(core: RefCounted) -> void:
	_core = core
	_core_region.clear()
	_core_floor = -1
	core.nav_clear_regions()
	for key: String in nav_regions:
		var reg := nav_regions[key] as NavigationRegion3D
		var arrays := _region_arrays(reg)
		_core_region[key] = core.nav_add_region(arrays[0], arrays[1], reg.enabled)
	if _floor_region != null:
		attach_floor(_floor_region)


## A navmesh region as the core takes it: its vertices in world space and its polygons ([n, i0 .. in-1, ...]).
func _region_arrays(reg: NavigationRegion3D) -> Array:
	var nm := reg.navigation_mesh
	var xf := reg.global_transform
	var verts := PackedVector3Array()
	for v in nm.get_vertices():
		verts.append(xf * v)
	var polys := PackedInt32Array()
	for i in nm.get_polygon_count():
		var poly := nm.get_polygon(i)
		polys.append(poly.size())
		polys.append_array(poly)
	return [verts, polys]


func _set_region(key: String, on: bool) -> void:
	(nav_regions[key] as NavigationRegion3D).enabled = on
	if _core != null and _core_region.has(key):
		_core.nav_set_region_enabled(_core_region[key], on)


func has_area(id: String) -> bool:
	return _scenes.has(id)


## The scene root of a loaded area (null when the area is not in this world): where an area's run-time dressing goes (the Warren's stair).
func area_node(id: String) -> Node3D:
	return _scenes.get(id)


# ---- the instance (the Depths; today's DmWorldBuilder.open_instance) -----------------------------------------------------------

## A run opens the Depths: `area_at` answers "depths" inside its rect until it closes. Its floor's navmesh is the floor's own (`attach_floor`).
func open_instance(id: String, open: bool) -> void:
	if id == "depths":
		depths_open = open


## The Depths floor's navmesh region is on the navigation map (the floor's node owns it) and now also the core's: its first floor adds a region, every later floor
## replaces that region's polygons, so nothing of an old floor piles up in the core's grid.
func attach_floor(region: NavigationRegion3D) -> void:
	_floor_region = region
	if _core == null:
		return
	var arrays := _region_arrays(region)
	if _core_floor < 0:
		_core_floor = int(_core.nav_add_region(arrays[0], arrays[1], true))
	else:
		_core.nav_replace_region(_core_floor, arrays[0], arrays[1], true)


## The floor is gone: its triangles leave the core's grid.
func detach_floor() -> void:
	_floor_region = null
	if _core != null and _core_floor >= 0:
		_core.nav_replace_region(_core_floor, PackedVector3Array(), PackedInt32Array(), false)


# ---- seals and doors (today's DmWorldBuilder.set_unlocked / set_door_open) -----------------------------------------------------

## Seals: `areas` = the area ids whose seal is broken; an area with no seal is always unlocked. Only loaded areas count. `quiet`: the doors that open say nothing
## (`door_opened` stays silent): the state a game is given as it loads or as a guest joins, not a seal breaking in front of the player.
func set_unlocked(areas: Array, quiet := false) -> void:
	unlocked.clear()
	var data: Dictionary = DmData.world()
	for id in loaded:
		var a: Dictionary = data["areas"][id]
		if a["unlock"] == null or areas.has(id):
			unlocked[id] = true
	_apply_unlock_state(quiet)


func _apply_unlock_state(quiet := false) -> void:
	for id in loaded:
		_set_region("area:" + id, unlocked.has(id))
	for d: Dictionary in DmData.world()["doors"]:
		if not nav_regions.has("door:" + String(d["id"])):
			continue
		if String(d["id"]) == "chapter_graves":
			_set_region("door:chapter_graves", true)
			for l: NavigationLink3D in nav_links["chapter_graves"]:
				l.enabled = true
		else:
			set_door_open(String(d["id"]), unlocked.has(String(d["a"])) and unlocked.has(String(d["b"])), true, quiet)


func set_door_open(id: String, open: bool, instant := false, quiet := false) -> void:
	if not gates.has(id):
		return
	var g: Dictionary = gates[id]
	if g.open == open:
		return
	g.open = open
	(g.collider as CollisionShape3D).set_deferred("disabled", open)
	var bars: Node3D = g.bars
	var y := 5.0 if open else 0.0
	if instant:
		bars.position.y = y
		bars.visible = not open
	else:
		bars.visible = true
		var tw := create_tween()
		tw.tween_property(bars, "position:y", y, 1.2)
		if open:
			tw.tween_callback(func() -> void: bars.visible = false)
	for l: NavigationLink3D in nav_links[id]:
		l.enabled = open
	_set_region("door:" + id, open)
	if open and not quiet:
		door_opened.emit(id)


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


## The area at a ground point ("" = outside every loaded area, a door corridor included): the rect test of the builder's `area_at`. The Depths count while a run has them open.
func area_at(x: float, z: float) -> String:
	for id in loaded:
		var r: Dictionary = _rects[id]
		if x >= r.x0 and x <= r.x1 and z >= r.z0 and z <= r.z1:
			return id
	if depths_open:
		var d: Dictionary = _rects["depths"]
		if x >= d.x0 and x <= d.x1 and z >= d.z0 and z <= d.z1:
			return "depths"
	return ""


func area_rect(id: String) -> Dictionary:
	return _rects.get(id, {})


## The areas' ground and their door corridors, and the Depths' rect when the Warren (whose stair leads there) is in the world: the combat core's bounds (its spatial grid) and the crowd's custom bounds.
func bounds(pad: float = 12.0) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var covered: Array = loaded.duplicate()
	if has_area("warren"):   # the Warren's stair leads to the Depths: a run's floors stand in their rect
		covered.append("depths")
	for id in covered:
		var r: Dictionary = _rects[id]
		lo = Vector2(minf(lo.x, float(r.x0)), minf(lo.y, float(r.z0)))
		hi = Vector2(maxf(hi.x, float(r.x1)), maxf(hi.y, float(r.z1)))
	return Rect2(lo - Vector2(pad, pad), hi - lo + Vector2(pad, pad) * 2.0)


## Where a hero starts and a fallen one gets up: today's Chapterhouse return point (areas.json CHAPTERHOUSE_RETURN) when the Chapterhouse is loaded;
## otherwise (a test's world) a walkable point just inside the area's door to the Chapterhouse: the door's centre across, the area's edge facing it less 3 m.
func spawn_point(id: String = "") -> Vector3:
	if id == "" and has_area("chapterhouse"):
		var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
		return Vector3(float(ret["x"]), 0.0, float(ret["z"]))
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
	if _core != null:
		return _core.nav_closest(p)
	var c := NavigationServer3D.map_get_closest_point(_map, p)
	return Vector3(c.x, 0.0, c.z)


## `p` itself when walkable (within 2 cm of the mesh), else the nearest walkable point: walking into a wall slides along it.
func nav_clamp(p: Vector3) -> Vector3:
	var c := nav_closest(p)
	return p if Vector2(c.x - p.x, c.z - p.z).length_squared() < 0.0004 else c
