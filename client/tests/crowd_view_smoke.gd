extends SceneTree
## The one rendered look at CrowdView (the headless proof is tests/crowd_view.gd): a core with a small party and a pack of enemies, drawn by the real
## renderer through the MultiMeshes DmCrowd writes, in the clips the core's states choose. Software GL, a few seconds, one screenshot.
## Run on the VPS (one rendered run at a time):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x720x24" timeout 90 \
##     /home/ubuntu/tools/godot/godot --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1280x720 --path client \
##     --script res://tests/crowd_view_smoke.gd -- --out=/abs/path/crowd_view_smoke.png
## Needs the models baked: bash client/tools/bake_crowd.sh robber hound && bash client/tools/bake_crowd.sh skeleton_thrall --assets=<repo>/godot/assets

const DT := 1.0 / 60.0


func _initialize() -> void:
	await process_frame
	var out := "/tmp/crowd_view_smoke.png"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var godot_dir := ProjectSettings.globalize_path("res://").path_join("../godot")
	var world := Node3D.new()
	root.add_child(world)
	var cam := Camera3D.new()
	cam.fov = 50.0
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 15, 17), Vector3(0, 0.5, 1))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	world.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.10, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.62)
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.22, 0.21, 0.2)
	ground.material_override = gm
	world.add_child(ground)

	var core: RefCounted = ClassDB.instantiate("DmCore")
	core.set_seed(5)
	DmCoreData.load_all(core, godot_dir)
	core.set_wander(false)
	core.set_area_bounds(Vector2(-40, -40), Vector2(40, 40))
	var view := CrowdView.new()
	view.auto_sync = false
	world.add_child(view)
	view.setup(core, DmCoreData.json(godot_dir.path_join("data/content/enemies.json"))["ENEMIES"], Vector2(-40, -40), Vector2(40, 40), {"assets_dir": CrowdBaker.default_assets_dir()})
	if view.model_slots().is_empty():
		printerr("FAIL crowd_view_smoke: bake the models first (see the header)")
		quit(1)
		return
	print("renderer: ", RenderingServer.get_video_adapter_name(), " ", RenderingServer.get_current_rendering_method(), "; models ", view.model_slots().keys(), "; ", view.warnings.size(), " fallbacks")
	var heroes := []
	for h in 2:
		var id: int = core.add_external(0, 0.4, 1.0)
		core.set_external(id, Vector2(-2.0 + 4.0 * h, 2.0), true)
		heroes.append(id)
		view.set_owner_legion(id, ["ossuary", "gravecaller"][h])
		for k in 6:
			core.raise_thrall({"kind": "warrior" if k < 5 else "hound", "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6,
				"empowered": false, "champion": false, "allyHeal": 0.0}, id, Vector2(-5.0 + 7.0 * h + float(k) * 0.9, 4.5), 0.0, 20.0)
	for e in 30:
		var a := float(e) / 30.0 * TAU
		core.spawn_enemy("robber" if e % 3 else "hound", Vector2(cos(a), sin(a)) * (9.0 + float(e % 4) * 1.5) + Vector2(0, 1), 1, 1000.0, 0.0, e == 7, "graves", e % 5 == 0)
	view.focus = Vector2(0, 2)
	# a few seconds of play, a tick per frame, then the picture
	for f in 150:
		core.step(DT)
		view.sync()
		core.take_events()
		await process_frame
	print("crowd: ", view.stats())
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(out)
	print("saved ", out, " ", img.get_size())
	quit(0)
