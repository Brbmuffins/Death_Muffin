extends SceneTree
## Builds a generated Depths floor in the world builder (headless smoke).  godot --headless --path godot --script res://tests/game/depths_builder_run.gd
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var ok := 0
	var bad := 0
	DmSimData.ensure()
	var b := DmWorldBuilder.new()
	root.add_child(b)
	b.build(DmData.world())
	var f := DmDepthsFloor.generate_floor(DmDepthsFloor.floor_seed(5, 5), 5, 5)
	b.open_instance("depths", true)
	b.build_depths_floor(f)
	b.set_depths_stair_open(true)
	b.set_depths_chest_opened(true)
	var fr: Node = b.area_nodes["depths"].get_node_or_null("DepthsFloor")
	if fr != null and fr.get_child_count() > 10: ok += 1
	else: bad += 1; printerr("FAIL floor root")
	b.clear_depths_floor()
	await process_frame
	if b.area_nodes["depths"].get_node_or_null("DepthsFloor") == null: ok += 1
	else: bad += 1; printerr("FAIL cleared")
	b.build_depths_floor(f)
	b.clear_depths_floor()
	print("%d passed, %d failed" % [ok, bad])
	quit(1 if bad > 0 else 0)
