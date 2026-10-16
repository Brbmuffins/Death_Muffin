extends SceneTree
## One rendered look at the crowd material (the only rendered check of client/crowd/): 55 baked robbers and a few hounds in MultiMeshes, in
## different clips, next to five skinned robbers posed the same as five of the baked ones. Software GL, one frame, one screenshot.
## Run on the VPS (one rendered run at a time):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x720x24" timeout 90 \
##     /home/ubuntu/tools/godot/godot --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1280x720 --path client \
##     --script res://tests/crowd_smoke.gd -- --out=/abs/path/crowd_smoke.png
## Needs the models baked: tools/bake_crowd.sh

const Baker := preload("res://crowd/crowd_baker.gd")
const PAIRS := [["walk", 0.5], ["run", 0.3], ["attack", 1.3], ["death", 2.0], ["hurt", 0.3]]


func _initialize() -> void:
	await process_frame
	var out := "/tmp/crowd_smoke.png"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var assets := Baker.default_assets_dir()
	var robber: CrowdVatData = load("res://crowd/baked/grave_robber/model.tres")
	var hound: CrowdVatData = load("res://crowd/baked/bone_hound/model.tres")
	if robber == null or hound == null:
		printerr("FAIL crowd_smoke: bake the models first (tools/bake_crowd.sh)")
		quit(1)
		return
	print("renderer: ", RenderingServer.get_video_adapter_name(), " ", RenderingServer.get_current_rendering_method())

	var world := Node3D.new()
	root.add_child(world)
	var cam := Camera3D.new()
	cam.fov = 48.0
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 8.5, 11.5), Vector3(0, 0.6, 0.5))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -28, 0)
	sun.shadow_enabled = false
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
	plane.size = Vector2(40, 40)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.22, 0.21, 0.2)
	ground.material_override = gm
	world.add_child(ground)

	# The crowd. Rows (front of the screen last): idle, walk, run, attack, mixed; then the paired row.
	var robber_mat := robber.make_material(_texture(assets.path_join(robber.albedo_path)), _texture(assets.path_join(robber.orm_path)))
	var hound_mat := hound.make_material(_texture(assets.path_join(hound.albedo_path)), _texture(assets.path_join(hound.orm_path)))
	var full := robber.make_multimesh(52)
	var far := robber.make_multimesh(3, 1)
	var n := 0
	var f := 0
	for row in 5:
		for col in 10:
			var pos := Vector3((col - 4.5) * 1.6, 0.0, (row - 3) * 1.9)
			var yaw := sin(float(row * 10 + col)) * 0.35
			var xf := Transform3D(Basis(Vector3.UP, yaw), pos)
			var clip := "idle"
			var t := float(col) * 1.37
			var tint := Color.WHITE
			var flash := 0.0
			var prev := 0
			var prev_t := 0.0
			var blend := 0.0
			match row:
				1:
					clip = "walk"
					t = float(col) * 0.23
				2:
					clip = "run"
					t = float(col) * 0.12
				3:
					clip = "attack"
					t = float(col) * 0.29
				4:
					if col < 5:
						clip = "death"
						t = float(col) * 0.8
					elif col < 8:
						clip = "hurt"
						t = float(col - 5) * 0.2
					elif col == 8:
						clip = "walk"
						t = 0.4
						prev = robber.clip_index("idle")
						prev_t = 2.0
						blend = 0.5
					else:
						tint = Color(1.0, 0.35, 0.3)
						flash = 0.6
			var ci := robber.clip_index(clip)
			var data := CrowdVatData.pack_custom(ci, t, prev, prev_t, blend)
			if row == 0 and col >= 7:
				far.set_instance_transform(f, xf)
				far.set_instance_color(f, CrowdVatData.pack_color(tint, flash))
				far.set_instance_custom_data(f, data)
				f += 1
			else:
				full.set_instance_transform(n, xf)
				full.set_instance_color(n, CrowdVatData.pack_color(tint, flash))
				full.set_instance_custom_data(n, data)
				n += 1
	# The pairs: skinned robber (left) and baked robber (right) in the same clip at the same moment.
	var refs: Array = []
	for i in PAIRS.size():
		var clip: String = PAIRS[i][0]
		var t: float = PAIRS[i][1]
		var x := -6.4 + float(i) * 1.5
		var m: Dictionary = Baker.load_model(root, "grave_robber", assets, Baker.default_rows_path())
		Baker.pose_at(m, clip, t)
		var rot := Basis(Vector3.UP, m.yaw)
		(m.root as Node3D).transform = Transform3D(Basis(Vector3.UP, 0.0), Vector3(x, 0, 4.2)) * Transform3D(rot * Basis.from_scale(Vector3.ONE * m.scale), rot * m.offset)
		refs.append(m)
		full.set_instance_transform(n, Transform3D(Basis.IDENTITY, Vector3(x + 7.0, 0, 4.2)))
		full.set_instance_color(n, CrowdVatData.pack_color(Color.WHITE, 0.0))
		full.set_instance_custom_data(n, CrowdVatData.pack_custom(robber.clip_index(clip), t))
		n += 1
	print("robbers placed: ", n, " + ", f, " far")
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = full
	mmi.material_override = robber_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(mmi)
	var mmf := MultiMeshInstance3D.new()
	mmf.multimesh = far
	mmf.material_override = robber_mat
	mmf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(mmf)

	# A few hounds at the back.
	var hounds := hound.make_multimesh(6)
	for i in 6:
		var clip: String = ["idle", "walk", "run"][i % 3]
		hounds.set_instance_transform(i, Transform3D(Basis(Vector3.UP, 0.4), Vector3(-4.5 + float(i) * 1.7, 0, -8.0)))
		hounds.set_instance_color(i, CrowdVatData.pack_color(Color.WHITE, 0.0))
		hounds.set_instance_custom_data(i, CrowdVatData.pack_custom(hound.clip_index(clip), 0.15 * float(i)))
	var hmi := MultiMeshInstance3D.new()
	hmi.multimesh = hounds
	hmi.material_override = hound_mat
	hmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(hmi)

	if DisplayServer.get_name() == "headless":   # a dry run: the scene builds, nothing renders
		print("headless: scene built, nothing rendered")
		for m in refs:
			(m.root as Node).free()
		quit(0)
		return

	# The buffer the combat core will write: transform rows, then colour, then custom data.
	var buf := full.buffer
	var o := 3 * CrowdVatData.BUFFER_STRIDE
	var xf3 := full.get_instance_transform(3)
	var cd3 := full.get_instance_custom_data(3)
	var layout_ok := buf.size() == full.instance_count * CrowdVatData.BUFFER_STRIDE and is_equal_approx(buf[o + 3], xf3.origin.x) and is_equal_approx(buf[o + 11], xf3.origin.z) \
		and is_equal_approx(buf[o + 16], cd3.r) and is_equal_approx(buf[o + 17], cd3.g) and is_equal_approx(buf[o + 12], 1.0)
	print("buffer layout (12 transform, 4 colour, 4 custom): ", "OK" if layout_ok else "MISMATCH size=%d" % buf.size())

	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(out)
	print("saved ", out, " ", img.get_size())
	for m in refs:
		(m.root as Node).free()
	quit(0 if layout_ok else 1)


func _texture(path: String) -> Texture2D:
	var img := Image.load_from_file(path)
	if img == null:
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
