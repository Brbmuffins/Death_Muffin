extends SceneTree
## Reference picture: the SAME boss events drawn through the current client's own harness (DmEventFx + DmBossView on a stub host, no slice). Compare with
## shot_late.gd. godot --rendering-driver opengl3 --path godot --script res://tests/next_bosses/shot_ref.gd -- --boss=saint --out=/some/dir  (renderer lock + xvfb)

const T := preload("res://tests/game/test_event_fx.gd")
var host
var fx: DmEventFx
var bv: DmBossView
var bs := DmBossState.new()
var out := ""
var boss_id := "saint"
var frame := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		if a.begins_with("--boss="):
			boss_id = a.substr(7)
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
	sun.light_energy = 0.7
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 45.0
	root.add_child(cam)
	cam.look_at_from_position(Vector3(2, 16, 16), Vector3(0, 0, 0), Vector3.UP)
	cam.make_current()
	host = T.StubHost.new()
	host.world_root = host
	host.sim = DmWorldSim.new(DmNav.new(), DmRng.new(3))
	host.p["x"] = 2.0
	host.p["z"] = 6.0
	host.area_id = "graves"
	root.add_child(host)
	fx = DmEventFx.new()
	fx.setup(host)
	bv = DmBossView.new()
	bv.setup(host, boss_id)
	bs.id = boss_id
	bs.active = true
	bs.x = 0.0
	bs.z = 0.0
	bs.hp = 1000.0
	bs.maxHp = 1000.0
	bs.state = "rain"
	await process_frame
	await process_frame
	var ev := {"t": "boss", "boss": boss_id, "x": 0.0, "z": 0.0, "phase": 1}
	match boss_id:
		"saint":
			ev.merge({"kind": "rotRain", "ms": 6000.0, "r": 2.0, "targets": [[2.0, 6.0], [-4.0, 3.0], [5.0, -2.0], [-2.0, -5.0]]})
		"regent":
			ev.merge({"kind": "conflagration", "ms": 6000.0, "r": 11.0, "targets": [[6.0, 2.0], [-6.0, 3.0], [1.0, -7.0], [-3.0, 8.0]]})
		_:
			ev.merge({"kind": "surface", "ms": 6000.0, "r": 3.7, "x": 5.0, "z": -2.0})
			bs.state = "sunk"
	fx.handle(ev)


func _process(delta: float) -> bool:
	frame += 1
	if host == null:
		return false
	host.now_ms += delta * 1000.0
	if fx != null:
		fx.update(delta)
	if bv != null:
		bv.sync(bs, delta)
	if frame == 45:
		_shot.call_deferred()
	return false


func _shot() -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(out)
	img.save_png("%s/%s_ref.png" % [out, boss_id])
	print("saved ", out, " ", img.get_size())
	quit()
