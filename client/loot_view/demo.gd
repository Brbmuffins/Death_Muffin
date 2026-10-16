extends Node3D
## Screenshot scene for DmLootView: a ring of drops of every rarity + gold piles + shards on a dark floor.
## usage: godot --path godot res://loot_view/demo.tscn -- --out=/path.png [--labels]

func _ready() -> void:
	var out := ""
	var labels := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a == "--labels":
			labels = true
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("0b0a10")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("6a6478")
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(30, 30)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("2a2630")
	floor_mi.material_override = fm
	add_child(floor_mi)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 7.5, 9)
	cam.rotation_degrees = Vector3(-38, 0, 0)
	cam.fov = 50
	add_child(cam)
	var lv := DmLootView.new()
	lv.show_labels = labels
	add_child(lv)
	var plain := [{"item_id": "ore_copper", "quantity": 3}, {"item_id": "helm_copper", "quantity": 1}]
	var drops: Array = [
		{"item_id": "ore_copper", "quantity": 3},
		{"item_id": "helm_copper", "quantity": 1, "instance": {"id": "a", "ilvl": 10, "affixes": [{"id": "p_thrall_dmg", "v": 5}]}},
		{"item_id": "helm_copper", "quantity": 1, "instance": {"id": "b", "ilvl": 10, "affixes": [{"id": "p_thrall_dmg", "v": 5}, {"id": "s_thrall_hp", "v": 5}]}},
		{"item_id": "ring_copper", "quantity": 1, "instance": {"id": "c", "ilvl": 10, "affixes": [{"id": "p_thrall_dmg", "v": 5}, {"id": "s_thrall_hp", "v": 5}, {"id": "p_withered", "v": 2}]}},
		{"item_id": "leg_legion_unburied_head", "quantity": 1},
	]
	for i in drops.size():
		lv.drop(drops[i], Vector3(-6.0 + i * 3.0, 0, -1.5), true)
	lv.drop({"kind": "gold", "amount": 6}, Vector3(-4, 0, 3), true)
	lv.drop({"kind": "gold", "amount": 40}, Vector3(-1.5, 0, 3), true)
	lv.drop({"kind": "shard", "amount": 3}, Vector3(2, 0, 3), true)
	lv.drop({"kind": "shard", "amount": 1}, Vector3(4, 0, 3.5), true)
	for i in 8:
		lv.tick(0.2, Vector3(99, 0, 99))
	if out != "":
		for i in 6:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png(out)
		get_tree().quit()
