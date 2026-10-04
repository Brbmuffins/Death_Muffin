extends SceneTree
## Rendered check of DmEventFx: a Gravedigger sweep + burial telegraph, a Regent ash-circle telegraph, a dirge and toxic and creeping
## miasma zone. godot --path godot --script res://tests/game/event_fx_shot.gd -- --out=shots/game/event_fx.png   (under the renderer lock)

const T := preload("res://tests/game/test_event_fx.gd")
var host
var fx: DmEventFx
var out := "shots/game/event_fx.png"
var frame := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	_build.call_deferred()


func _build() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("0b0810")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("2a2433")
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.1
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("2a2430")
	fm.roughness = 1.0
	floor_mesh.material_override = fm
	floor_mesh.position.y = -0.02
	root.add_child(floor_mesh)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 0.5
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 45.0
	root.add_child(cam)
	cam.look_at_from_position(Vector3(0, 24, 20), Vector3(0, 0, -2), Vector3.UP)
	cam.make_current()
	var hero := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.4
	cap.height = 1.8
	hero.mesh = cap
	hero.position = Vector3(0, 0.9, 6)
	root.add_child(hero)
	host = T.StubHost.new()
	host.world_root = host
	host.sim = DmWorldSim.new(DmNav.new(), DmRng.new(3))
	host.p["x"] = 0.0
	host.p["z"] = 6.0
	host.area_id = "graves"
	root.add_child(host)
	fx = DmEventFx.new()
	fx.setup(host)
	await process_frame
	await process_frame
	var boss_ev := func(kind: String, boss: String, x: float, z: float, extra: Dictionary) -> Dictionary:
		var e := {"t": "boss", "kind": kind, "boss": boss, "x": x, "z": z, "phase": 1}
		e.merge(extra)
		return e
	fx.handle(boss_ev.call("sweep", "gravedigger", -9.0, -2.0, {"ms": 4000.0, "r": 4.5, "dir": 0.9}))
	fx.handle(boss_ev.call("bury", "gravedigger", -9.0, -2.0, {"ms": 4000.0, "targets": [[-3.0, 3.0], [-6.0, 5.0], [-1.0, 7.0]]}))
	fx.handle(boss_ev.call("conflagration", "regent", 9.0, -4.0, {"ms": 4000.0, "r": 8.0, "targets": [[6.0, -2.0], [12.0, -5.0], [8.0, -8.0]]}))
	fx.handle(boss_ev.call("lance", "abbess", 0.0, -14.0, {"ms": 4000.0, "r": 11.0, "dir": 0.0}))
	var z1 := DmSimZone.new()
	z1.id = 1
	z1.kind = "dirge"
	z1.x = 10.0
	z1.z = 6.0
	z1.r = 4.0
	z1.until = 60.0
	fx.handle({"t": "zone", "zone": z1, "by": "me"})
	var z2 := DmSimZone.new()
	z2.id = 2
	z2.kind = "toxic"
	z2.hostile = true
	z2.x = -12.0
	z2.z = 8.0
	z2.r = 3.5
	z2.until = 60.0
	fx.handle({"t": "zone", "zone": z2})
	var z3 := DmSimZone.new()
	z3.id = 3
	z3.kind = "miasma"
	z3.x = 0.0
	z3.z = 12.0
	z3.r = 3.0
	z3.until = 60.0
	fx.handle({"t": "zone", "zone": z3, "by": "me"})


func _process(delta: float) -> bool:
	frame += 1
	host.now_ms += delta * 1000.0
	if fx != null:
		fx.update(delta)
	if frame == 40:
		_shot.call_deferred()
	return false


func _shot() -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(out.get_base_dir() if out.is_absolute_path() else ProjectSettings.globalize_path("res://").path_join(out.get_base_dir()))
	var path := out if out.is_absolute_path() else ProjectSettings.globalize_path("res://").path_join(out)
	img.save_png(path)
	print("saved ", path, " ", img.get_size())
	quit()
