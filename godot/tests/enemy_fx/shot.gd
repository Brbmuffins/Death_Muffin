extends SceneTree
## Rendered check: penitent cone, sac slam, moth dust, ghoul eruption ring, an elite, a censer. Under the renderer lock:
## flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" godot --rendering-driver opengl3 --path godot --script res://tests/enemy_fx/shot.gd -- --out=/abs/enemy-fx.png

var out := "shots/enemy_fx.png"
var frame := 0
var fxn: DmEnemyFx
var es: Array = []

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
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var fl := MeshInstance3D.new()
	var pl := PlaneMesh.new()
	pl.size = Vector2(80, 80)
	fl.mesh = pl
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("2a2430")
	fl.material_override = fm
	root.add_child(fl)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 0.5
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 45.0
	root.add_child(cam)
	cam.look_at_from_position(Vector3(0, 22, 18), Vector3(0, 0, -1), Vector3.UP)
	cam.make_current()
	var v: Node = root.get_node_or_null("Vfx")
	if v == null:
		v = DmFxRuntime.new()
		v.name = "Vfx"
		root.add_child(v)
	fxn = DmEnemyFx.new()
	fxn.player_pos = func() -> Vector3: return Vector3(0, 0, 6)
	root.add_child(fxn)
	var spots := {"penitent": Vector3(-8, 0, -4), "sac": Vector3(-2, 0, -4), "moth": Vector3(5, 0, -4), "censer": Vector3(10, 0, 4)}
	for k in spots:
		var e: DmEnemy = load("res://enemies/%s.tscn" % k).instantiate()
		e.position = spots[k]
		e.wander_enabled = false
		root.add_child(e)
		e.set_physics_process(false)
		es.append(e)
	var el: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	el.elite = true
	el.rising = true
	el.position = Vector3(-10, 0, 6)
	root.add_child(el)
	el.set_physics_process(false)
	await process_frame
	await process_frame
	for e in es.slice(0, 3):
		e.aim = e.global_position + Vector3(0, 0, 6)
		e.announce_telegraph(4.0)
	var gh: DmEnemy = load("res://enemies/ghoul.tscn").instantiate()
	gh.position = Vector3(2, 0, 8)
	root.add_child(gh)
	gh.set_physics_process(false)
	gh.aim = Vector3(2, 0, 8)
	gh.telegraph.emit(&"erupt", gh.global_position, gh.aim, 1.8, 4.0)

func _process(_d: float) -> bool:
	frame += 1
	if frame == 50:
		_shot.call_deferred()
	return false

func _shot() -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := out if out.is_absolute_path() else ProjectSettings.globalize_path("res://").path_join(out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	print("saved ", path, " draw calls ", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	quit(0)
