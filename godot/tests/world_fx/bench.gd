extends SceneTree
## Rendered A/B harness for the world dressing (NOT a unit test; needs a display, ONE renderer at a time: use bench.sh).
## For each requested area: one screenshot with the dressing on and one off, plus frame time / draw calls / objects / primitives with
## the dressing off, on, and (for the --features areas) each piece on its own. llvmpipe numbers are RELATIVE only.
##   args after `--`:  --out=<dir>  --areas=a,b,c  --features=a,b  --frames=N  --res=WxH

var out_dir := "res://../shots/world_fx"
var areas: PackedStringArray = []
var feature_areas: PackedStringArray = []
var frames := 45
var lights := -1   # --lights=N: prop lights on at once (Ultra = 14); default the builder's
var rounds := 3
var rows: Array = []
var b: DmWorldBuilder
var cam: DmCameraRig
var dr: DmWorldDressing
var marker: Node3D

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--areas="):
			areas = a.substr(8).split(",")
		elif a.begins_with("--features="):
			feature_areas = a.substr(11).split(",")
		elif a.begins_with("--lights="):
			lights = int(a.substr(9))
		elif a.begins_with("--rounds="):
			rounds = int(a.substr(9))
		elif a.begins_with("--frames="):
			frames = int(a.substr(9))
	DirAccess.make_dir_recursive_absolute(out_dir)
	_load_spots()
	_run.call_deferred()

var spots: Dictionary = {}

func _load_spots() -> void:
	# the web's arrival positions (tests/world_fx: web-arrival capture writes spots.json); falls back to each area's centre
	var p := ProjectSettings.globalize_path("res://") + "shots/world_fx/spots.json"
	if FileAccess.file_exists(p):
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if v is Dictionary:
			spots = v

func _spot(id: String) -> Vector3:
	if spots.has(id):
		return Vector3(float(spots[id].x), 0, float(spots[id].z))
	var w: Dictionary = DmData.world()
	var r: Dictionary = w.areas[id].rect
	var c := Vector3((float(r.x0) + float(r.x1)) / 2.0, 0, (float(r.z0) + float(r.z1)) / 2.0)
	# the Nave/Fen are lit down the middle; stand a little inside so the windows and water read
	return c

func _settle(n: int) -> void:
	for i in n:
		await process_frame

func _measure(label: String, area: String) -> void:
	await _settle(6)
	var t0 := Time.get_ticks_usec()
	var worst := 0.0
	var dc := 0
	var objs := 0
	var prims := 0
	var cpu := 0.0
	var last := Time.get_ticks_usec()
	for i in frames:
		await process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, float(now - last) / 1000.0)
		last = now
		dc += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		objs += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
		prims += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
		cpu += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / frames
	var row := {"area": area, "mode": label, "frame_ms": snappedf(ms, 0.01), "worst_ms": snappedf(worst, 0.1), "draw_calls": dc / frames, "objects": objs / frames, "primitives": prims / frames, "script_ms": snappedf(cpu / frames, 0.001)}
	rows.append(row)
	print("[bench] ", JSON.stringify(row))

func _shot(name: String) -> void:
	await _settle(4)
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [out_dir, name])

func _only(f: String) -> void:
	for g in DmWorldDressing.FEATURES:
		dr.features[g] = (g == f)
	dr.set_enabled(true)

func _go(id: String) -> void:
	var p := _spot(id)
	marker.global_position = p
	cam.snap(p)
	b.update_streaming(p.x, p.z)
	b.update_light_lod(p.x, p.z)
	b.set_area(id)

func _run() -> void:
	var w: Dictionary = DmData.world()
	b = DmWorldBuilder.new()
	root.add_child(b)
	b.build(w)
	b.open_all()
	if lights > 0:
		b.light_near = lights
	cam = DmCameraRig.new()
	root.add_child(cam)
	cam.setup(w.camera)
	marker = Node3D.new()
	var cm := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.35
	cap.height = 1.7
	cm.mesh = cap
	cm.position.y = 0.85
	marker.add_child(cm)
	root.add_child(marker)
	dr = DmWorldDressing.attach(b, marker)
	await _settle(20)
	if areas.is_empty():
		areas = PackedStringArray(w.order)
	for id in areas:
		_go(id)
		dr.set_enabled(false)
		await _settle(8)
		await _shot("%s_off" % id)
		await _measure("off", id)
		dr.set_enabled(true)
		await _settle(8)
		await _shot("%s_on" % id)
		await _measure("on", id)
		if feature_areas.has(id):
			# interleaved A/B: off, only_X, off, only_X ... (the VPS is shared; wall time drifts, so every X is bracketed by its own baseline)
			for f in DmWorldDressing.FEATURES:
				for rnd in rounds:
					dr.set_enabled(false)
					await _measure("base_" + f, id)
					_only(f)
					await _measure("only_" + f, id)
				await _shot("%s_only_%s" % [id, f])
			for g in DmWorldDressing.FEATURES:
				dr.features[g] = true
			dr.set_enabled(true)
	var f := FileAccess.open("%s/bench.json" % out_dir, FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "\t"))
	f.close()
	print("[bench] done")
	quit()
