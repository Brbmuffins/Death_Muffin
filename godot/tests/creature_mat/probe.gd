extends SceneTree
## Rendered probe (NOT pass/fail): 40 creatures of the live enemy looks (plain, elite, risen, winged, spectral thrall with rim + gear tint, some mid hit
## flash, some fading) in one frame; prints unique materials, shader materials, draw calls, objects, primitives. Hold the renderer lock:
##   flock -w 1200 /home/ubuntu/death-muffin/qa-browser.lock xvfb-run -a -s "-screen 0 1280x720x24" nice -n 10 godot --rendering-driver opengl3 --path godot \
##     --script res://tests/creature_mat/probe.gd -- [--out=/abs/dir] [--mode=grid|show]
## grid = the 40-body field; show = a close lineup (plain, hit flash, fading corpse, elite, thrall, winged). Screenshots land in --out.

var frame := 0
var mode := "grid"
var out := ""
var cs: Array = []

func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d

func _initialize() -> void:
	mode = _arg("mode", "grid")
	out = _arg("out", "")
	_build.call_deferred()

func _build() -> void:
	seed(7)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("0b0810")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("2a2433")
	env.ambient_light_energy = 0.7
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
	sun.light_energy = 0.8
	sun.shadow_enabled = true
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 45.0
	root.add_child(cam)
	cam.make_current()
	var looks: Array = [
		["grave_robber", {"hitstop": true}], ["bone_hound", {"hitstop": true}], ["penitent", {"hitstop": true}],
		["carrion_sac", {"hitstop": true}], ["skeleton_thrall", {"hitstop": true, "tint": 0x8a8078, "emissive": 0x2a3a18, "emissive_intensity": 0.3}],
		["deacon", {"hitstop": true}], ["shroud_moth", {"hitstop": true, "fallback": "choir_wraith", "wings": {"speed": 14.0, "amp": 0.6, "body": 0.3}}],
		["grave_robber", {"hitstop": true, "emissive": 0x4a1f8a, "emissive_intensity": 0.14}],
	]
	var thrall := {"gear_tint": false, "tint": 0xf4ecff, "emissive": 0x1f8f86, "emissive_intensity": 0.18, "spectral": false,
		"rim": {"color": 0x6fe0b0, "strength": 1.0}}
	var wraith := {"gear_tint": false, "tint": 0xb9c4ff, "emissive": 0x8f9ed1, "emissive_intensity": 1.1, "spectral": true,
		"rim": {"color": 0x6fe0b0, "strength": 1.0}}
	if mode == "show":
		var row: Array = [
			["grave_robber", {"hitstop": true}, "plain"], ["grave_robber", {"hitstop": true}, "flash"], ["grave_robber", {"hitstop": true}, "fade"],
			["grave_robber", {"hitstop": true, "emissive": 0x4a1f8a, "emissive_intensity": 0.14}, "plain"],
			["skeleton_thrall", thrall, "plain"], ["skeleton_thrall", wraith, "plain"], ["shroud_moth", looks[6][1], "plain"],
		]
		for i in row.size():
			var c := DmCreature.new(row[i][0], row[i][1])
			c.root.position = Vector3(-6.0 + i * 2.0, 0, 0)
			root.add_child(c.root)
			if row[i][2] == "flash":
				c.set_flash(1.0)
			elif row[i][2] == "fade":
				c.set_opacity(0.45)
			cs.append(c)
		cam.look_at_from_position(Vector3(0, 2.2, 10.5), Vector3(0, 1.0, 0), Vector3.UP)
	else:
		for i in 40:
			var lk: Array = looks[i % looks.size()]
			var o: Dictionary = lk[1]
			var slug: String = lk[0]
			if i % 10 == 9:
				slug = "skeleton_thrall"
				o = thrall if i % 20 == 9 else wraith
			var c := DmCreature.new(slug, o)
			c.root.position = Vector3(-8.5 + (i % 8) * 2.4, 0, -4.0 + (i / 8) * 2.6)
			root.add_child(c.root)
			if i % 7 == 3:
				c.set_flash(1.0)
			if i % 9 == 4:
				c.set_opacity(0.45)
			cs.append(c)
		cam.look_at_from_position(Vector3(0, 13, 14), Vector3(0, 0.5, 0), Vector3.UP)

func _process(_d: float) -> bool:
	frame += 1
	if frame == 12:
		_report.call_deferred()
	return false

func _report() -> void:
	var mats := {}
	var shaders := 0
	var surfaces := 0
	for c in cs:
		for mi in (c.root as Node).find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			for s in m.mesh.get_surface_count():
				var mt := m.get_active_material(s)
				surfaces += 1
				if mt != null:
					mats[mt.get_instance_id()] = mt
	for k in mats:
		if mats[k] is ShaderMaterial:
			shaders += 1
	print("PROBE mode=%s creatures=%d surfaces=%d unique_materials=%d unique_shader_materials=%d" % [mode, cs.size(), surfaces, mats.size(), shaders])
	print("PROBE draw_calls=%d objects=%d primitives=%d" % [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
	if out != "":
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		root.get_texture().get_image().save_png(out)
		print("PROBE shot ", out)
	quit()
