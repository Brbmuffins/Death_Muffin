extends SceneTree
## Rendered before/after of the mote rings in a saturated fight: miasma cloud + corpse explosions + litany, seeded, fixed 30 fps so
## every frame is reproducible. Writes <out>_<frame>.png and prints live motes / uploaded bytes / ring update ms per frame.
##   flock -w 1200 /home/ubuntu/death-muffin/qa-browser.lock xvfb-run -a -s "-screen 0 1280x720x24" nice -n 10 godot --path godot \
##     --fixed-fps 30 --resolution 1280x720 --script res://tests/perf/fx_mote_shot.gd -- --out=/tmp/shots/a
## llvmpipe timings are not GPU numbers; the images and the counts are what this compares.

var _fx: DmFxRuntime
var _out := "/tmp/fx_mote"
var _frame := 0
const SHOTS := [12, 30, 52, 80]


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	seed(42)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("0b0810")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("2a2433")
	env.glow_enabled = true
	env.glow_intensity = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var fl := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	fl.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("1b1722")
	fl.material_override = fm
	root.add_child(fl)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 0.5
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.transform = Transform3D(Basis.looking_at(Vector3(0, -13, -10)), Vector3(0, 13, 9))
	root.add_child(cam)
	cam.current = true
	_fx = DmFxRuntime.new()
	root.add_child(_fx)


func _process(_dt: float) -> bool:
	_frame += 1
	var f := _frame
	if f < 70:
		# miasma cloud: rot smoke + spores, every 4th frame; corpse explosions every 9th; litany ring every 15th
		if f % 4 == 1:
			_fx.emit_smoke({"x": -4.0, "y": 0.3, "z": 0.0, "count": 14, "color": DmFxData.spell("miasma", "rot"), "spread": 2.2, "speed": 0.5, "up": 0.7, "life": 2.4, "size": 1.3})
			_fx.emit({"x": -4.0, "y": 0.4, "z": 0.0, "count": 40, "color": DmFxData.spell("miasma", "rot"), "spread": 2.2, "speed": 0.4, "up": 0.9, "life": 2.0, "size": 0.2, "gravity": -0.2})
		if f % 9 == 1:
			var cx := randf_range(-1.0, 4.5)
			_fx.emit({"x": cx, "y": 0.6, "z": randf_range(-3.0, 2.0), "count": 160, "color": DmFxData.spell("detonate", "hot"), "spread": 0.4, "speed": 5.0, "up": 4.0, "life": 1.1, "size": 0.28, "gravity": 6.0})
			_fx.emit_smoke({"x": cx, "y": 0.4, "z": 0.0, "count": 30, "color": DmFxData.spell("detonate", "smoke"), "spread": 0.5, "speed": 1.2, "up": 1.0, "life": 1.8, "size": 1.0})
		if f % 15 == 1:
			_fx.emit({"x": 0.0, "y": 0.2, "z": 1.0, "count": 220, "color": DmFxData.spell("litany", "hot"), "spread": 3.2, "speed": 0.8, "up": 2.2, "life": 1.4, "size": 0.22, "drag": 0.8})
	var add: DmFxRing = _fx.prims.additive
	var sm: DmFxRing = _fx.prims.smoke
	if f % 5 == 0:
		var ub: Variant = add.get("last_upload_bytes")
		print("MOTES frame %d live add=%d smoke=%d upload add=%s B" % [f, add.active(), sm.active(), str(ub) if ub != null else str(add.capacity * 64)])
	if f in SHOTS:
		RenderingServer.frame_post_draw.connect(func(): root.get_texture().get_image().save_png("%s_%03d.png" % [_out, f]), CONNECT_ONE_SHOT)
	return f >= 90
