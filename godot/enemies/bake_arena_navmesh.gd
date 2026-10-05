extends SceneTree
## Bakes the arena's NavigationMesh from its static colliders and writes res://enemies/test_arena_navmesh.res.
## godot --headless --path godot --script res://enemies/bake_arena_navmesh.gd

func _initialize() -> void:
	_bake.call_deferred()

func _bake() -> void:
	var arena: Node3D = load("res://enemies/test_arena.tscn").instantiate()
	arena.set("robber_count", 0)
	root.add_child(arena)
	var region: NavigationRegion3D = arena.get_node("NavRegion")
	var nm: NavigationMesh = region.navigation_mesh
	nm.clear()
	region.bake_navigation_mesh(false)
	print("polygons: ", nm.get_polygon_count(), " vertices: ", nm.get_vertices().size())
	var err := ResourceSaver.save(nm, "res://enemies/test_arena_navmesh.res")
	print("save: ", error_string(err))
	quit(0 if err == OK and nm.get_polygon_count() > 0 else 1)
