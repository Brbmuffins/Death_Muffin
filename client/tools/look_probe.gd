extends SceneTree
## The look probe: today's game and the rebuilt client on the same camera, as numbers and pictures (client/README.md "The look against today's game"). NOT a pass/fail suite.
## One script for BOTH projects, run on the VPS under the renderer lock, one run at a time (software GL, about 5 minutes each):
##   rebuilt client (Forward+, Vulkan on lavapipe):
##     VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x720x24" timeout 600 \
##       /home/ubuntu/tools/godot/godot --rendering-method forward_plus --rendering-driver vulkan --resolution 1280x720 --path client --script res://tools/look_probe.gd -- --out=/abs/dir --tag=fwd
##   today's game (Compatibility, OpenGL on llvmpipe; the script is read from the client's folder, nothing is copied; its start takes 3 to 4 minutes):
##     flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x720x24" timeout 900 \
##       /home/ubuntu/tools/godot/godot --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1280x720 --path godot --script /abs/path/client/tools/look_probe.gd -- --out=/abs/dir --tag=today --part=game
## --part=game|calib|glow|both (default both), --plan="chapterhouse:base,nomoon;graves:base" (an area, then the variants to shoot: base, unfix, unlift, unpool, nomoon, norim, noshadow, noglow, nossao, nofog, nodress: the world dressing off, before: what the first test builds drew: no dressing, a plain sphere at every light and the glow of the time),
## --frames=N (frames to wait after a change, 3), --warm=N (after the hero's move, 12). The game part starts the real game scene offline at Ultra with the hero at a fixed spot of each area,
## saves <tag>_<area>_<variant>.png and prints a STAT line each (mean colour, luminance and its 10th, 50th and 90th percentile, the colour shares; the hero's own box left out). The calibration part
## shows one test object at a time on a grey plane under the game's environment (fog, specular, vertex colours, HDR, blends, emission) and prints a CAL2 line each: the same lines from both
## projects say where the renderers differ. `--part=glow --glow="<name>:<key>=<v>,<key>=<v>;<name>:..."` shoots the two bright things of the calibration (the HDR albedo quad, a small bright emission) under each glow setting of the
## list and prints a GLOW line each: the sRGB along the row through the thing, from its edge outwards (keys: lv the seven level weights "a/b/c/d/e/f/g", int, thr, scale, cap, strength, off=1 for no glow; an unnamed key keeps the game's `DmWfxBloom`
## value); "game" is the game's own setting. Compare the lines with the same part run on today's game. The rebuilt-client-only variants (unfix, unlift, unpool) need next/look/dm_compat_albedo.gd and are skipped on today's game; `before` and the glow's keys other than `game` are for the rebuilt client too.


const SPOTS := {
	"graves": Vector3(0, 0, -16), "chapterhouse": Vector3(0, 0, 20), "ossuary": Vector3(48, 0, -20), "nave": Vector3(0, 0, -70),
	"fen": Vector3(-42, 0, -80), "pyre": Vector3(90, 0, -116), "sanctum": Vector3(0, 0, -116), "acre": Vector3(40, 0, 20),
}
var out := ""
var tag := ""
var frames_per := 3
var warm := 12

# the calibration part's nodes
var env: Environment
var cam: Camera3D
var holder: Node3D
var moon: DirectionalLight3D
var rim: DirectionalLight3D
var plane: MeshInstance3D
var plane_mat: StandardMaterial3D


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _initialize() -> void:
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _stats(img: Image, label: String) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var n := 0
	var sr := 0.0
	var sg := 0.0
	var sb := 0.0
	var ys: Array = []
	var cx0 := int(w * 0.35)
	var cx1 := int(w * 0.65)
	var cy0 := int(h * 0.25)
	var cy1 := int(h * 0.75)
	for y in range(0, h, 3):
		for x in range(0, w, 3):
			if x > cx0 and x < cx1 and y > cy0 and y < cy1:
				continue
			var c := img.get_pixel(x, y)
			sr += c.r
			sg += c.g
			sb += c.b
			n += 1
			ys.append(0.299 * c.r + 0.587 * c.g + 0.114 * c.b)
	ys.sort()
	var m := sr + sg + sb
	print("STAT %s mean_srgb=(%.1f %.1f %.1f) Y=%.1f p10=%.1f p50=%.1f p90=%.1f share_rgb=(%.3f %.3f %.3f)" % [label, 255.0 * sr / n, 255.0 * sg / n, 255.0 * sb / n,
		255.0 * (0.299 * sr + 0.587 * sg + 0.114 * sb) / n, 255.0 * ys[int(n * 0.1)], 255.0 * ys[int(n * 0.5)], 255.0 * ys[int(n * 0.9)], sr / m, sg / m, sb / m])


# ---------------------------------------------------------------- part 1: the game
func _lifted_mats(game_root: Node) -> Array:
	# every StandardMaterial3D with a texture whose tint the albedo table lifted: [material, lifted colour, original colour] (the rebuilt client only)
	var res: Array = []
	var albedo: Variant = load("res://next/look/dm_compat_albedo.gd") if ResourceLoader.exists("res://next/look/dm_compat_albedo.gd") else null
	if albedo == null:
		return res
	var seen := {}
	for n in game_root.find_children("*", "MeshInstance3D", true, false):
		var m := (n as MeshInstance3D).material_override as StandardMaterial3D
		if m == null or m.albedo_texture == null or seen.has(m):
			continue
		seen[m] = true
		var tex := m.albedo_texture.resource_path.get_file().get_basename()
		for key: String in albedo.TABLE:
			if key.begins_with(tex + "|"):
				var tint := Color.html("#" + key.get_slice("|", 1))
				if albedo.tint(tex, tint).is_equal_approx(m.albedo_color):
					res.append([m, m.albedo_color, tint])
					break
	return res


func _set_lift(mats: Array, on: bool) -> void:
	for e in mats:
		(e[0] as StandardMaterial3D).albedo_color = e[1] if on else e[2]


func _set_pool_srgb(game_root: Node, on: bool) -> void:
	for n in game_root.find_children("light_pools", "MeshInstance3D", true, false):
		var m := (n as MeshInstance3D).material_override as StandardMaterial3D
		if m != null:
			m.vertex_color_is_srgb = on


func _game() -> void:
	var plan := _arg("plan", "chapterhouse:base;graves:base;ossuary:base").split(";")
	DirAccess.make_dir_recursive_absolute(out)
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("look%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	var t0 := Time.get_ticks_msec()
	await g.start(c.data, api, {"persist": false, "waves": false, "audio": false, "name": "look", "settings": {"graphics": "ultra", "auto_res": false, "brightness": 1.0}})
	print("renderer: %s %s; started in %d ms; viewport %s" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_method(), Time.get_ticks_msec() - t0, root.get_viewport().get_visible_rect().size])
	var b: DmWorldBuilder = g.world.builder
	var e: Environment = b.env
	print("ENV tonemap=%d exposure=%.3f ambient_color=%s energy=%.3f glow=%s fog_end=%.1f moon=(%s %.3f shadow %s) rim=(%s %.3f)" % [e.tonemap_mode, e.tonemap_exposure, e.ambient_light_color, e.ambient_light_energy, e.glow_enabled, e.fog_depth_end, b.moon.light_color, b.moon.light_energy, b.moon.shadow_enabled, b.rim.light_color, b.rim.light_energy])
	var lifted := _lifted_mats(g.world)
	var spheres: Array = []
	env = e
	print("lifted materials: %d" % lifted.size())
	var hb := g.local_body()
	await _frames(20)
	var ssao_on: bool = e.ssao_enabled if e.get("ssao_enabled") != null else false
	for entry in plan:
		var area := entry.get_slice(":", 0)
		var variants := entry.get_slice(":", 1).split(",")
		hb.teleport(SPOTS[area])
		g.camera.snap(hb.position)
		await _frames(warm)
		print("AREA %s current_area=%s ambient=%s exposure=%.3f" % [area, b.current_area, e.ambient_light_color, e.tonemap_exposure])
		for v in variants:
			# restore
			e.glow_enabled = true
			DmWfxBloom.apply(e, true)
			if g.world.dressing != null:
				g.world.dressing.set_enabled(true)
			for sp in spheres:
				sp.queue_free()
			spheres.clear()
			if e.get("ssao_enabled") != null:
				e.set("ssao_enabled", ssao_on)
			b.moon.visible = true
			b.rim.visible = true
			b.moon.shadow_enabled = true
			_set_lift(lifted, true)
			_set_pool_srgb(g.world, true)
			var exp0 := e.tonemap_exposure
			match v:
				"unfix":
					_set_lift(lifted, false)
					_set_pool_srgb(g.world, false)
				"unlift":
					_set_lift(lifted, false)
				"unpool":
					_set_pool_srgb(g.world, false)
				"nomoon":
					b.moon.visible = false
				"norim":
					b.rim.visible = false
				"noshadow":
					b.moon.shadow_enabled = false
				"noglow":
					e.glow_enabled = false
				"nossao":
					if e.get("ssao_enabled") != null:
						e.set("ssao_enabled", false)
				"nofog":
					e.fog_enabled = false
				"nodress":
					g.world.dressing.set_enabled(false)
				"before":
					g.world.dressing.set_enabled(false)
					_glow_apply({"lv": ".56/.58/.6/.62/.64", "int": "0.75", "thr": "0.85", "scale": "2", "cap": "12", "strength": "1"})   # (the first test builds' glow)
					for l in g.world.find_children("*", "OmniLight3D", true, false):
						var sph := MeshInstance3D.new()
						var sm := SphereMesh.new()
						sm.radius = 0.1
						sm.height = 0.2
						sm.radial_segments = 8
						sm.rings = 4
						sph.mesh = sm
						var fm := StandardMaterial3D.new()
						fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
						fm.albedo_color = (l as OmniLight3D).light_color.lightened(0.3)
						sph.material_override = fm
						sph.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
						l.add_child(sph)
						spheres.append(sph)
			await _frames(frames_per)
			var img := root.get_viewport().get_texture().get_image()
			e.fog_enabled = true
			e.tonemap_exposure = exp0
			if img == null or img.is_empty():
				print("no image")
				continue
			img.convert(Image.FORMAT_RGB8)
			img.save_png("%s/%s_%s_%s.png" % [out, tag, area, v])
			_stats(img, "%s %s %s" % [tag, area, v])
	print("game part done")
	g.queue_free()
	await _frames(3)


# ---------------------------------------------------------------- part 2: calibration scenes
func _avg(img: Image, x: int, y: int) -> String:
	var r := 0.0
	var gg := 0.0
	var b := 0.0
	var n := 0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var c := img.get_pixel(clampi(x + dx, 0, img.get_width() - 1), clampi(y + dy, 0, img.get_height() - 1))
			r += c.r
			gg += c.g
			b += c.b
			n += 1
	return "%3d,%3d,%3d" % [255.0 * r / n, 255.0 * gg / n, 255.0 * b / n]


func _shot(label: String, spots: Array) -> void:
	for i in 3:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		print("no image")
		return
	img.convert(Image.FORMAT_RGB8)
	img.save_png("%s/%s_%s.png" % [out, tag, label])
	var k := float(img.get_width()) / 1280.0
	var s := ""
	for p: Vector2i in spots:
		s += "(%d,%d)=%s  " % [p.x, p.y, _avg(img, int(p.x * k), int(p.y * k))]
	print("CAL2 %s %s: %s" % [tag, label, s])


func _clear() -> void:
	for c in holder.get_children():
		c.queue_free()
	await process_frame


func _quad(size: float, y: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.orientation = PlaneMesh.FACE_Y
	mi.mesh = q
	mi.position = Vector3(0, y, 0)
	return mi


func _vc_mesh(col: Color, size: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var q := [Vector3(-size, 0, -size), Vector3(size, 0, -size), Vector3(size, 0, size), Vector3(-size, 0, size)]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_color(col)
		st.set_normal(Vector3.UP)
		st.add_vertex(q[i])
	return st.commit()


const VC_SHADER := "shader_type spatial;\nrender_mode unshaded;\nvoid fragment() { ALBEDO = COLOR.rgb; }\n"


## The calibration stage: the game's environment (fog, ambient, ACES at the game's exposure), camera, moon and rim light over a grey plane.
func _calib_stage() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html("#07060a")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.2697, 0.2151, 0.4079)
	env.ambient_light_energy = 1.9
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.44
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	holder = Node3D.new()
	root.add_child(holder)
	cam = Camera3D.new()
	cam.fov = 40.0
	cam.far = 260.0
	root.add_child(cam)
	cam.current = true
	cam.look_at_from_position(Vector3(0, 14, 17), Vector3(0, 0.6, 0))
	moon = DirectionalLight3D.new()
	moon.light_color = Color(0.6039, 0.651, 0.8314)
	moon.light_energy = 1.44
	root.add_child(moon)
	moon.look_at_from_position(Vector3(-14, 30, 12), Vector3.ZERO)
	rim = DirectionalLight3D.new()
	rim.light_color = Color(0.4784, 0.3608, 0.8392)
	rim.light_energy = 0.88
	root.add_child(rim)
	rim.look_at_from_position(Vector3(6, 10, -24), Vector3.ZERO)
	plane = _quad(600.0, 0.0)
	plane_mat = StandardMaterial3D.new()
	plane_mat.albedo_color = Color(0.5, 0.5, 0.5)
	plane_mat.roughness = 0.62
	plane.material_override = plane_mat
	root.add_child(plane)


func _calib() -> void:
	_calib_stage()
	var screen_rows := [Vector2i(640, 700), Vector2i(640, 560), Vector2i(640, 420), Vector2i(640, 330), Vector2i(640, 260), Vector2i(640, 200), Vector2i(640, 150), Vector2i(640, 110), Vector2i(640, 80)]
	var centre := [Vector2i(640, 360), Vector2i(700, 360), Vector2i(780, 360), Vector2i(900, 360)]
	await _frames(2)
	moon.visible = false
	rim.visible = false
	env.fog_enabled = false
	await _shot("g1_ground_nofog_ambient", screen_rows)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_density = 1.0
	env.fog_depth_begin = 0.0
	env.fog_depth_curve = 1.0
	env.fog_depth_end = 130.0
	env.fog_sky_affect = 0.0
	env.fog_light_color = Color(0.051, 0.0392, 0.0784)
	await _shot("g2_ground_fog_ambient", screen_rows)
	env.fog_light_color = Color(0.5, 0.5, 0.5)
	await _shot("g2b_ground_fog_grey_ambient", screen_rows)
	env.fog_light_color = Color(0.051, 0.0392, 0.0784)
	moon.visible = true
	rim.visible = true
	await _shot("g3_ground_fog_all_lights", screen_rows)
	env.fog_enabled = false
	await _shot("g4_ground_nofog_all_lights", screen_rows)
	plane_mat.roughness = 0.95
	await _shot("g5_ground_rough95_all_lights", screen_rows)
	plane_mat.roughness = 0.45
	await _shot("g6_ground_rough45_all_lights", screen_rows)
	moon.shadow_enabled = true
	await _shot("g7_ground_rough45_moon_shadow_on", screen_rows)
	plane_mat.roughness = 0.62
	plane.visible = false
	moon.visible = false
	rim.visible = false
	env.ambient_light_energy = 0.0
	for srgb in [false, true]:
		var sfx := "_srgb" if srgb else ""
		var mi := MeshInstance3D.new()
		mi.mesh = _vc_mesh(Color(0.5, 0.4, 0.3), 3.0)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = srgb
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = m
		holder.add_child(mi)
		await _shot("v1_vertexcolor_std" + sfx, centre)
		var mi2 := MeshInstance3D.new()
		mi2.mesh = _vc_mesh(Color(0.25, 0.17, 0.09, 1.0), 3.0)
		var m2 := StandardMaterial3D.new()
		m2.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m2.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m2.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m2.vertex_color_use_as_albedo = true
		m2.vertex_color_is_srgb = srgb
		m2.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi2.material_override = m2
		holder.add_child(mi2)
		mi.visible = false
		await _shot("v2_vertexcolor_addpool" + sfx, centre)
		mi2.visible = false
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		var qm := QuadMesh.new()
		qm.size = Vector2(6, 6)
		qm.orientation = PlaneMesh.FACE_Y
		mm.mesh = qm
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D(Basis.IDENTITY, Vector3(0, 0.02, 0)))
		mm.set_instance_color(0, Color(0.5, 0.4, 0.3))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var m3 := StandardMaterial3D.new()
		m3.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m3.vertex_color_use_as_albedo = true
		m3.vertex_color_is_srgb = srgb
		m3.cull_mode = BaseMaterial3D.CULL_DISABLED
		mmi.material_override = m3
		holder.add_child(mmi)
		await _shot("v3_multimesh_color_std" + sfx, centre)
		mmi.queue_free()
		if not srgb:
			var mi4 := MeshInstance3D.new()
			mi4.mesh = _vc_mesh(Color(0.5, 0.4, 0.3), 3.0)
			var sm := ShaderMaterial.new()
			sm.shader = Shader.new()
			sm.shader.code = VC_SHADER
			mi4.material_override = sm
			holder.add_child(mi4)
			await _shot("v4_vertexcolor_shader", centre)
			mi4.queue_free()
		await _clear()
	# the fx layer's shader (DmFxTex) with a colour that is an sRGB hex value: 0x806040 on a white texture
	var mi7 := _quad(6.0, 0.02)
	var shm := ShaderMaterial.new()
	shm.shader = DmFxTex.shader("beam", false)
	mi7.material_override = shm
	var mm7 := MultiMesh.new()
	mm7.transform_format = MultiMesh.TRANSFORM_3D
	mm7.use_colors = true
	mm7.use_custom_data = true
	var qm7 := QuadMesh.new()
	qm7.size = Vector2(6, 6)
	qm7.orientation = PlaneMesh.FACE_Y
	mm7.mesh = qm7
	mm7.instance_count = 1
	mm7.set_instance_transform(0, Transform3D(Basis.IDENTITY, Vector3(0, 0.02, 0)))
	mm7.set_instance_color(0, Color(0.5, 0.4, 0.3))
	mm7.set_instance_custom_data(0, Color(1, 1, 1, 1))
	var mmi7 := MultiMeshInstance3D.new()
	mmi7.multimesh = mm7
	mmi7.material_override = shm
	mi7.queue_free()
	holder.add_child(mmi7)
	await _shot("f1_fxtex_beam_hex806040", centre)
	await _clear()
	for k in 3:
		var mi5 := _quad(6.0, 0.02)
		var m6 := StandardMaterial3D.new()
		m6.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if k == 0:
			m6.albedo_color = Color(2, 1.77, 0.81)
		elif k == 1:
			m6.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m6.albedo_color = Color(1, 1, 1, 0.5)
		else:
			m6.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m6.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			m6.albedo_color = Color(0.5, 0.4, 0.3, 0.6)
		mi5.material_override = m6
		holder.add_child(mi5)
		DmWfxBloom.apply(env, false)
		await _shot("h%d_%s_noglow" % [k, ["hdr_albedo", "alpha_mix", "add_alpha"][k]], centre)
		DmWfxBloom.apply(env, true)
		await _shot("h%d_%s_glow" % [k, ["hdr_albedo", "alpha_mix", "add_alpha"][k]], centre)
		await _clear()
	var mi6 := _quad(6.0, 0.02)
	var m7 := StandardMaterial3D.new()
	m7.albedo_color = Color(0, 0, 0)
	m7.emission_enabled = true
	m7.emission = Color(0.5, 0.3, 0.1)
	mi6.material_override = m7
	holder.add_child(mi6)
	await _shot("e1_emission", centre)
	m7.emission_energy_multiplier = 6.0
	m7.emission = Color(1, 0.9, 0.7)
	mi6.scale = Vector3(0.15, 1, 0.15)
	var bright := [Vector2i(640, 360), Vector2i(660, 360), Vector2i(690, 360), Vector2i(740, 360), Vector2i(820, 360), Vector2i(940, 360)]
	DmWfxBloom.apply(env, true)
	await _shot("e2_emission_bright_small_glow", bright)
	DmWfxBloom.apply(env, false)
	await _shot("e3_emission_bright_small_noglow", bright)
	print("calib part done")


# ---------------------------------------------------------------- part 3: the glow's reach
func _glow_cfg(spec: String) -> Dictionary:
	var kv := {}
	for tok in spec.split(",", false):
		var p := tok.split("=", false, 1)
		if p.size() == 2:
			kv[p[0]] = p[1]
	return kv


## The glow of `env` as the game sets it (DmWfxBloom), then the keys of `kv` over it.
func _glow_apply(kv: Dictionary) -> void:
	DmWfxBloom.apply(env, not kv.has("off"))
	if kv.has("int"):
		env.glow_intensity = float(kv["int"])
	if kv.has("strength"):
		env.glow_strength = float(kv["strength"])
	if kv.has("thr"):
		env.glow_hdr_threshold = float(kv["thr"])
	if kv.has("scale"):
		env.glow_hdr_scale = float(kv["scale"])
	if kv.has("cap"):
		env.glow_hdr_luminance_cap = float(kv["cap"])
	if kv.has("lv"):
		var w := String(kv["lv"]).split("/", false)
		for i in 7:
			env.set_glow_level(i, float(w[i]) if i < w.size() else 0.0)


func _row(img: Image, y: int, x0: int, n: int, step: int) -> String:
	var s := ""
	for i in n:
		var c := img.get_pixel(clampi(x0 + i * step, 0, img.get_width() - 1), y)
		s += "%d,%d,%d " % [255.0 * c.r, 255.0 * c.g, 255.0 * c.b]
	return s.strip_edges()


func _glow() -> void:
	_calib_stage()
	await _frames(2)
	plane.visible = false
	moon.visible = false
	rim.visible = false
	env.ambient_light_energy = 0.0
	env.fog_enabled = false
	var list := _arg("glow", "game").split(";", false)
	for entry in list:
		var name := entry.get_slice(":", 0)
		var kv := _glow_cfg(entry.get_slice(":", 1)) if entry.contains(":") else {}
		for scene in ["h0", "e2"]:
			var mi: MeshInstance3D = _quad(6.0, 0.02)
			var m := StandardMaterial3D.new()
			if scene == "h0":
				m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				m.albedo_color = Color(2, 1.77, 0.81)
			else:
				m.albedo_color = Color(0, 0, 0)
				m.emission_enabled = true
				m.emission = Color(1, 0.9, 0.7)
				m.emission_energy_multiplier = 6.0
				mi.scale = Vector3(0.15, 1, 0.15)
			mi.material_override = m
			holder.add_child(mi)
			_glow_apply(kv)
			await _frames(3)
			var img := root.get_viewport().get_texture().get_image()
			if img == null or img.is_empty():
				print("no image")
				continue
			img.convert(Image.FORMAT_RGB8)
			var k := float(img.get_width()) / 1280.0
			# the row through the thing's middle (h0: its right edge at x 790, e2: x 661), outwards
			var y := int((389.0 if scene == "h0" else 381.0) * k)
			var x0 := int((790.0 if scene == "h0" else 661.0) * k)
			print("GLOW %s %s %s y=%d x0=%d step=%d: %s" % [tag, name, scene, y, x0, 2, _row(img, y, x0, 40 if scene == "h0" else 36, 2)])
			if _arg("save", "") == name:
				img.save_png("%s/%s_glow_%s_%s.png" % [out, tag, name, scene])
			mi.queue_free()
			await process_frame
	print("glow part done")


func _run() -> void:
	out = _arg("out", "/tmp")
	tag = _arg("tag", "x")
	frames_per = int(_arg("frames", "3"))
	warm = int(_arg("warm", "12"))
	var part := _arg("part", "both")
	DirAccess.make_dir_recursive_absolute(out)
	if part == "game" or part == "both":
		await _game()
	if part == "calib" or part == "both":
		await _calib()
	if part == "glow":
		await _glow()
	print("look_probe done")
	quit()
