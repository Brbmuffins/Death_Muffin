extends SceneTree
## Rendered check of DmAbilitySystem (Vfx visible): a few rites cast against a real DmWorldSim, captured to a PNG.
## flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x800x24" timeout 300 \
##   godot --rendering-driver opengl3 --resolution 1280x800 --fixed-fps 30 --path godot --script res://tests/game/ability_fx_shot.gd -- --out=shots/ability_fx.png
## Args: --out=file.png  --frames=44 (frame of the capture)  --ids=a,b,c (rites to cast; default a spread of the necromancer kit)

var _t: RefCounted
var _w: Dictionary
var _now := [1000.0]
var _markers: Dictionary = {}


func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var out := String(args.get("out", "shots/ability_fx.png"))
	var shot_frame := int(args.get("frames", 44))
	var ids: Array = String(args.get("ids", "bone_prison,grave_hands,bone_storm,miasma,corpse_explosion,marrow_spear,grave_frost,bone_mantle,rally_dead,black_litany")).split(",")
	_build_stage()
	await process_frame
	_t = load("res://tests/game/test_ability_fx.gd").new()
	var host: RefCounted = _t.StubHost.new()
	_w = _t.make(true, "necromancer", _t.MODS, _t.LOADOUT, {}, 0.5, host)
	_t.setup_thralls(_w, _now)
	var ab: DmAbilitySystem = _w["c"]
	_w["p"]["resource"]["value"] = 1000.0
	await process_frame
	var idx := 0
	var frame := 0
	while frame < shot_frame + 4:
		frame += 1
		if frame % 3 == 1 and idx < ids.size():
			_w["p"]["castUntil"] = 0.0
			_w["p"]["cooldowns"].clear()
			var id: String = ids[idx]
			var res := ab.cast(id, _t.target_for(_w, id), _now[0])
			print("cast %s -> %s" % [id, res])
			idx += 1
		_now[0] += 1000.0 / 30.0
		var sim: DmWorldSim = _w["sim"]
		var p: Dictionary = _w["p"]
		sim.set_player(DmSimPlayer.make("p1", p["x"], p["z"], p["area"], p["alive"], 60.0, "necromancer"))
		ab.update(_now[0], 1.0 / 30.0)
		for ev in sim.step(1.0 / 30.0):
			ab.handle_event(ev)
		_sync_markers(sim, p)
		await process_frame
		if frame == shot_frame:
			var img := root.get_texture().get_image()
			DirAccess.make_dir_recursive_absolute(out.get_base_dir())
			img.save_png(out)
			print("saved ", out, " stats ", ab.stats)
	quit(0)


func _build_stage() -> void:
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
	var fl := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	fl.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("1b1722")
	fm.roughness = 1.0
	fl.material_override = fm
	fl.position = Vector3(0, -0.02, -16)
	root.add_child(fl)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 0.5
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 45.0
	root.add_child(cam)
	cam.look_at_from_position(Vector3(0, 12.0, -6.5), Vector3(0, 0, -16.5), Vector3.UP)
	cam.current = true


func _marker(key: String, color: Color, h: float) -> MeshInstance3D:
	if _markers.has(key):
		return _markers[key]
	var m := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.28
	cap.height = h
	m.mesh = cap
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	m.material_override = mat
	root.add_child(m)
	_markers[key] = m
	return m


func _sync_markers(sim: DmWorldSim, p: Dictionary) -> void:
	var hero := _marker("hero", Color("c9b8e8"), 1.7)
	hero.position = Vector3(p["x"], 0.85, p["z"])
	for e: DmSimEnemy in sim.enemies.values():
		_marker("e%d" % e.id, Color("8a2c3c"), 1.6).position = Vector3(e.x, 0.8, e.z)
	for t: DmSimThrall in sim.thralls.values():
		_marker("t%d" % t.id, Color("6fe3c8"), 1.4).position = Vector3(t.x, 0.7, t.z)
	for c: DmSimCorpse in sim.corpses.values():
		var m := _marker("c%d" % c.id, Color("5a5046"), 0.5)
		m.position = Vector3(c.x, 0.15, c.z)
		m.rotation_degrees = Vector3(90, 0, 0)
