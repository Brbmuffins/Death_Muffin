extends SceneTree
## The one rendered look at the crowd's alpha path (the headless proof is tests/crowd_view.gd, the draw calls tests/draw_budget.gd; client/crowd/README.md "The alpha path"): three robbers
## in a row, one solid, one under the Shrouded ward (it eases to 0.38) and one that leaves the core and sinks away (opacity 1 - sink_t / 0.9), drawn by the real renderer through the
## crowd's fade group (blend_mix, no depth write) and compared by pixels. A body's "ink" is how far the top 1.1 m of it stands out from the ground (the mean colour distance to the ground
## in the same row, off to the side, over the body's column): a see-through body has less, though not exactly its opacity's share, because the robber's mesh is two-sided and its far side
## shows through the near one (today's fade variant does the same: the robber is not one of DmCreatureMat's cull-back bodies). The sinking body's top is found in each picture, since it
## goes down (the opacity is read from the instance row the crowd uploaded, since a software-GL frame takes as long as it takes). Software GL, a few seconds, three screenshots.
## `-- --analyze=/abs/prefix --ward=0.38 --mid=0.65 --late=0.2` redoes the measuring on the pictures a run saved, headless.
## Run on the VPS (one rendered run at a time):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x720x24" timeout 120 \
##     /home/ubuntu/tools/godot/godot --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1280x720 --path client \
##     --script res://tests/crowd_fade_smoke.gd -- --out=/abs/path/crowd_fade
## Needs the robber baked: bash client/tools/bake_crowd.sh robber

const DT := 1.0 / 60.0
const XS := [-3.0, 0.0, 3.0]   ## the control, the shrouded one, the one that sinks

var fails := 0
var view: CrowdView


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL crowd_fade_smoke: " + what)
	else:
		print("ok   " + what)


## The first row (from the top) where something stands out from the ground in the columns x0 to x1, and how much the 1.1 m (110 rows at this camera) from there do: the mean colour distance
## of each pixel to the pixel in the same row at column 100, which is ground (the plane is lit the same all along a row).
func body_ink(img: Image, x0: int, x1: int) -> Vector2:
	var top := -1
	for y in range(200, img.get_height() - 120):
		var ref := img.get_pixel(100, y)
		for x in range(x0, x1):
			if dist(img.get_pixel(x, y), ref) > 0.06:
				top = y
				break
		if top >= 0:
			break
	if top < 0:
		return Vector2(-1.0, 0.0)
	var sum := 0.0
	var n := 0
	for y in range(top, top + 110):
		var ref := img.get_pixel(100, y)
		for x in range(x0, x1):
			sum += dist(img.get_pixel(x, y), ref)
			n += 1
	return Vector2(float(top), sum / float(n))


## The measuring: the three bodies' columns are 300 pixels wide round their places (the pictures are 1280 wide and the bodies 3 m apart).
func analyze(ward_img: Image, mid_img: Image, late_img: Image, shrouded_o: float, mid_o: float, late_o: float) -> void:
	var cols := [[170, 470], [490, 790], [810, 1110]]
	var control := body_ink(ward_img, cols[0][0], cols[0][1])
	var ward := body_ink(ward_img, cols[1][0], cols[1][1])
	var before := body_ink(ward_img, cols[2][0], cols[2][1])
	var mid := body_ink(mid_img, cols[2][0], cols[2][1])
	var late := body_ink(late_img, cols[2][0], cols[2][1])
	print("ink (colour distance to the ground in the row, top at row): control %.3f (%d), shrouded %.3f (%d; %.2f of the control's, its opacity %.3f); the sinking one %.3f (%d) solid, %.3f (%d) at opacity %.3f (%.2f), %.3f (%d) at %.3f (%.2f)" % [
		control.y, control.x, ward.y, ward.x, ward.y / maxf(control.y, 1e-6), shrouded_o, before.y, before.x, mid.y, mid.x, mid_o, mid.y / maxf(before.y, 1e-6), late.y, late.x, late_o, late.y / maxf(before.y, 1e-6)])
	check(control.y > 0.05, "the solid body stands out from the ground (%.3f)" % control.y)
	check(ward.y > 0.15 * control.y and ward.y < 0.85 * control.y, "the body under the ward (opacity %.2f) is there but see-through: %.2f of the solid one's ink" % [shrouded_o, ward.y / maxf(control.y, 1e-6)])
	check(mid.y > 0.2 * before.y and mid.y < 0.95 * before.y and mid.x > before.x + 15.0, "the sinking body (opacity %.2f) is lower and fainter: %.2f of its solid ink, its top %d rows down" % [mid_o, mid.y / maxf(before.y, 1e-6), int(mid.x - before.x)])
	check(late.y < mid.y and late.y < 0.5 * before.y, "and fainter still near the end (opacity %.2f): %.2f" % [late_o, late.y / maxf(before.y, 1e-6)])


## The opacity the crowd uploaded for the instance standing at x (the ground x of the row's origin): INSTANCE_CUSTOM.x over the clip index, as crowd_vat.gdshader reads it. 1 when it is in no fade group.
func fade_opacity(x: float) -> float:
	var crowd: RefCounted = view.crowd
	for slot in view.model_slots().values():
		for lod in 3:
			var buf: PackedFloat32Array = crowd.buffer(slot, lod, false, true)
			for i in buf.size() / 20:
				if absf(buf[i * 20 + 3] - x) < 0.3:
					var cx := buf[i * 20 + 16]
					return clampf(1.0 - (cx - floorf(cx + 0.001)) * (64.0 / 63.0), 0.0, 1.0)
	return 1.0


func dist(a: Color, b: Color) -> float:
	return (Vector3(a.r, a.g, a.b) - Vector3(b.r, b.g, b.b)).length()


func _initialize() -> void:
	await process_frame
	var out := "/tmp/crowd_fade"
	var redo := ""
	var opac := {"ward": 0.38, "mid": 0.65, "late": 0.2}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--analyze="):
			redo = a.substr(10)
		elif a.begins_with("--ward="):
			opac["ward"] = float(a.substr(7))
		elif a.begins_with("--mid="):
			opac["mid"] = float(a.substr(6))
		elif a.begins_with("--late="):
			opac["late"] = float(a.substr(7))
	if redo != "":   # the measuring alone, on the pictures a rendered run saved
		analyze(Image.load_from_file(redo + "_ward.png"), Image.load_from_file(redo + "_sinking.png"), Image.load_from_file(redo + "_late.png"), opac["ward"], opac["mid"], opac["late"])
		quit(1 if fails > 0 else 0)
		return
	var data_dir := "res://"   # this project's data/: the same files the game loads
	var world := Node3D.new()
	root.add_child(world)
	var cam := Camera3D.new()
	cam.fov = 40.0
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 3.2, 9.0), Vector3(0, 1.0, 0))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.shadow_enabled = true
	world.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.10, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.66)
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.55, 0.52, 0.46)   # light, so that a body that is see-through shows the ground through it
	ground.material_override = gm
	world.add_child(ground)

	var core: RefCounted = ClassDB.instantiate("DmCore")
	core.set_seed(5)
	DmCoreData.load_all(core, data_dir)
	core.set_wander(false)
	core.set_area_bounds(Vector2(-40, -40), Vector2(40, 40))
	view = CrowdView.new()
	view.auto_sync = false
	world.add_child(view)
	view.setup(core, DmCoreData.json(data_dir.path_join("data/content/enemies.json"))["ENEMIES"], Vector2(-40, -40), Vector2(40, 40), {"assets_dir": CrowdBaker.default_assets_dir()})
	if not view.model_slots().has("grave_robber"):
		printerr("FAIL crowd_fade_smoke: bake the robber first (see the header)")
		quit(1)
		return
	print("renderer: ", RenderingServer.get_video_adapter_name(), " ", RenderingServer.get_current_rendering_method())
	var ids := []
	for k in 3:
		ids.append(core.spawn_enemy("robber", Vector2(XS[k], 0.0), 1, 1000.0, 0.0, false, "graves", false, PackedStringArray(["shrouded"]) if k == 1 else PackedStringArray()))
	view.focus = Vector2(0, 0)
	for f in 120:   # two seconds: the ward has been up for most of it, and the body has eased to 0.38
		core.step(DT)
		view.sync()
		core.take_events()
		await process_frame
	var first: Dictionary = view.crowd.view_info(ids[1])
	print("shrouded: veiled %s, opacity %.3f, fade_q %d; crowd %s" % [first.veiled, first.opacity, first.fade_q, view.stats()])
	check(bool(first.veiled) and float(first.opacity) < 0.4 and int(view.stats().faded) == 1, "the shrouded body is in the fade group at about 0.38 (%.3f)" % float(first.opacity))
	await RenderingServer.frame_post_draw
	var solid_img := root.get_viewport().get_texture().get_image()
	solid_img.save_png(out + "_ward.png")
	# the one that sinks leaves the core: captured at about a third of the way through its sink (the opacity is read from its instance row), and near the end
	var shrouded_o := fade_opacity(XS[1])
	core.remove_enemy(ids[2])
	var mid_o := 1.0
	var late_o := 1.0
	var mid_img: Image = null
	var late_img: Image = null
	for f in 600:
		core.step(DT)
		view.sync()
		core.take_events()
		await process_frame
		var o := fade_opacity(XS[2])
		if mid_img == null and o < 0.72:
			await RenderingServer.frame_post_draw
			mid_o = fade_opacity(XS[2])
			mid_img = root.get_viewport().get_texture().get_image()
			mid_img.save_png(out + "_sinking.png")
			print("sinking, mid: opacity %.3f; crowd %s" % [mid_o, view.stats()])
			check(int(view.stats().fading) == 1 and int(view.stats().faded) == 2, "the sinking body is in the fade group beside the shrouded one (%d fading, %d faded)" % [view.stats().fading, view.stats().faded])
		elif mid_img != null and o < 0.3:
			await RenderingServer.frame_post_draw
			late_o = fade_opacity(XS[2])
			late_img = root.get_viewport().get_texture().get_image()
			late_img.save_png(out + "_late.png")
			print("sinking, late: opacity %.3f" % late_o)
			break
	check(mid_img != null and late_img != null, "both pictures were taken (mid %.3f, late %.3f)" % [mid_o, late_o])
	if mid_img == null or late_img == null:
		quit(1)
		return
	analyze(solid_img, mid_img, late_img, shrouded_o, mid_o, late_o)
	if fails > 0:
		printerr("FAIL crowd_fade_smoke: %d checks failed" % fails)
		quit(1)
		return
	print("PASS crowd_fade_smoke")
	quit(0)
